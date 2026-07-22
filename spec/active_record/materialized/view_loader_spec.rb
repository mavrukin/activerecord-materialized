# frozen_string_literal: true

require "open3"
require "tmpdir"
require "tempfile"
require "spec_helper"

# #134 — under Zeitwerk's lazy loading (config.eager_load = false: development/test) a view class
# whose constant nothing has referenced yet is never loaded, so its depends_on commit callbacks are
# never installed and writes to its dependencies don't schedule maintenance. The Railtie's
# config.to_prepare hook (ActiveRecord::Materialized.load_views!) eager-loads the view directories so
# the callbacks are wired regardless. This is exercised in a subprocess against a real, lazy-loaded
# Rails application, since the callback-install timing only matters inside the Rails boot sequence.
EAGER_LOAD_GEM_ROOT = File.expand_path("../../..", __dir__).freeze

RSpec.describe ActiveRecord::Materialized::ViewLoader do
  # A minimal Rails app: eager_load off (the lazy case), a dependency model + a view in app/models,
  # and a probe that writes to the dependency WITHOUT ever referencing the view constant, then checks
  # whether the view was marked dirty — i.e. whether its after_commit callback was installed.
  def boot_script(eager_load:)
    <<~RUBY
      $LOAD_PATH.unshift(File.join(#{EAGER_LOAD_GEM_ROOT.inspect}, "lib"))
      require "active_record"
      require "action_controller/railtie"
      require "activerecord/materialized"

      app_root = Dir.mktmpdir
      Dir.mkdir(File.join(app_root, "app"))
      Dir.mkdir(File.join(app_root, "app", "models"))
      File.write(File.join(app_root, "app", "models", "widget.rb"), <<~MODEL)
        class Widget < ActiveRecord::Base; end
      MODEL
      File.write(File.join(app_root, "app", "models", "widget_tally.rb"), <<~VIEW)
        class WidgetTally < ActiveRecord::Materialized::View
          self.table_name = "mv_widget_tallies"
          materialized_from do
            Widget.group(:category).select(Widget.arel_table[:category], Widget.arel_table[:id].count.as("tally"))
          end
          depends_on Widget
        end
      VIEW

      APP_ROOT = app_root
      MODELS_DIR = File.join(app_root, "app", "models")
      class TestApp < Rails::Application
        config.load_defaults 8.0
        config.eager_load = #{eager_load}
        config.hosts.clear
        config.secret_key_base = "x" * 30
        config.logger = Logger.new(IO::NULL)
        config.root = APP_ROOT
        config.autoload_paths << MODELS_DIR
        config.eager_load_paths << MODELS_DIR
      end
      TestApp.initialize!

      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
      ActiveRecord::Base.connection.create_table(:widgets) { |t| t.string :category }

      # Write to the dependency WITHOUT referencing the WidgetTally constant first.
      Widget.create!(category: "a")

      # If the view's after_commit callback was installed at boot, the write marked it dirty.
      dirty = ActiveRecord::Materialized::Registry.find("widget_tally")&.dirty?
      print(dirty ? "dirty" : "not-dirty")
    RUBY
  end

  def run_boot(eager_load:)
    Bundler.with_unbundled_env do
      Tempfile.create(["eager_probe", ".rb"]) do |file|
        file.write(boot_script(eager_load: eager_load))
        file.flush
        Open3.capture2e("bundle", "exec", "ruby", file.path, chdir: EAGER_LOAD_GEM_ROOT)
      end
    end
  end

  it "installs a view's depends_on callbacks on boot even with eager_load off" do
    output, status = run_boot(eager_load: false)

    expect(status).to be_success, "subprocess failed:\n#{output}"
    expect(output).to end_with("dirty") # the write reached the view => its callback was installed at boot
  end
end
