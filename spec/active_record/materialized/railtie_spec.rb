# frozen_string_literal: true

require "open3"
require "tempfile"
require "spec_helper"

# The Railtie is only required when Rails is present, so the gem's normal
# (Rails-free) specs never exercise that conditional require. Load the gem in a
# subprocess with Rails defined to guard the require path — a regression test
# for the entry point pointing at lib/activerecord/activerecord/... instead of
# lib/activerecord/materialized/railtie.
RAILTIE_PROBE_ROOT = File.expand_path("../../..", __dir__).freeze
RAILTIE_PROBE_SCRIPT = <<~RUBY.freeze
  $LOAD_PATH.unshift(File.join(#{RAILTIE_PROBE_ROOT.inspect}, "lib"))
  require "active_record"
  require "rails/railtie"
  require "activerecord/materialized"
  print(defined?(ActiveRecord::Materialized::Railtie) ? "loaded" : "missing")
RUBY

RSpec.describe "Railtie loading under Rails" do # rubocop:disable RSpec/DescribeClass
  it "requires the Railtie without a LoadError" do
    output, status = Bundler.with_unbundled_env do
      Tempfile.create(["railtie_probe", ".rb"]) do |file|
        file.write(RAILTIE_PROBE_SCRIPT)
        file.flush
        Open3.capture2e("bundle", "exec", "ruby", file.path, chdir: RAILTIE_PROBE_ROOT)
      end
    end

    expect(status).to be_success, "subprocess failed:\n#{output}"
    expect(output).to eq("loaded")
  end
end
