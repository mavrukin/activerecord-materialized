# frozen_string_literal: true

require "bundler/setup"
require "active_record"
require "active_support/core_ext/integer/time"
require "active_support/testing/time_helpers"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.join(ROOT, "lib")

require "active_support/time"

Time.zone = "UTC"

require "activerecord-materialized"

RSpec.configure do |config|
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
    ActiveRecord::Materialized::Registry.send(:reset!)
    ActiveRecord::Materialized::DependencyRegistry.reset!
    ActiveRecord::Materialized::ChangeSubscriber.install!
  end

  config.before(:each) do
    unless RSpec.current_example.metadata[:benchmark]
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
      ActiveRecord::Base.connection.create_table :items, force: true do |t|
        t.string :category, null: false
        t.integer :amount, null: false
      end
    end
    ActiveRecord::Materialized::Registry.send(:reset!)
  end
end
