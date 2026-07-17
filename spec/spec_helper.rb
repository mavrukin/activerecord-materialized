# frozen_string_literal: true

require "bundler/setup"
require "active_record"
require "active_support/core_ext/integer/time"
require "active_support/testing/time_helpers"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.join(ROOT, "lib")

require "active_support/time"

require "activerecord/materialized"
require_relative "support/view_sources"
require_relative "support/materialized_view_helpers"

class Item < ActiveRecord::Base
end

RSpec.configure do |config|
  config.include MaterializedViewHelpers

  config.around do |example|
    Time.use_zone("UTC") { example.run }
  end

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.include ActiveSupport::Testing::TimeHelpers
  config.order = :random
  Kernel.srand config.seed

  config.before(:suite) do
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Base.connection.create_table :items, force: true do |t|
      t.string :category, null: false
      t.integer :amount, null: false
    end
    ActiveRecord::Materialized::TableModelRegistry.register(Item)
    ActiveRecord::Materialized::Registry.send(:reset!)
    ActiveRecord::Materialized::DependencyRegistry.reset!
  end

  config.before(:each) do
    # Deterministic dispatch default for the suite: the in-process refresher, which the specs
    # drive via AsyncRefresher.flush!/pause. (The gem's real default auto-resolves to :active_job
    # when ActiveJob is loaded — which it is here — so without this pin, writes would fan out to
    # background job threads and race the assertions.) The :active_job specs opt in with their own
    # `before`, which runs after this one.
    ActiveRecord::Materialized.configuration.refresh_dispatcher = :async
    ActiveRecord::Materialized::AsyncRefresher.reset!
    ActiveRecord::Materialized::AsyncRefresher.paused = false
    unless RSpec.current_example.metadata[:benchmark] || RSpec.current_example.metadata[:db_matrix]
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
      ActiveRecord::Base.connection.create_table :items, force: true do |t|
        t.string :category, null: false
        t.integer :amount, null: false
      end
      ActiveRecord::Materialized::TableModelRegistry.register(Item)
      ActiveRecord::Materialized::Registry.send(:reset!)
      ActiveRecord::Materialized::DependencyRegistry.reset!
    end
  end
end
