# frozen_string_literal: true

require "spec_helper"
require_relative "adapters"
require_relative "support/integration_schema"

# Shared setup for :db_matrix examples: connect to a given adapter, provision the
# schema fresh, and reset the gem's global registries — mirroring spec_helper's
# per-example reset, but pointed at a real database.
module IntegrationHelper
  def establish_adapter!(profile)
    ActiveRecord::Base.establish_connection(profile.connection_config)
    IntegrationSchema.provision!
    ActiveRecord::Materialized::Registry.send(:reset!)
    ActiveRecord::Materialized::DependencyRegistry.reset!
    ActiveRecord::Materialized::AsyncRefresher.reset!
  end

  def seed_line_items(*rows)
    IntegrationSchema::LineItem.delete_all
    rows.each { |category, amount| IntegrationSchema::LineItem.create!(category: category, amount: amount) }
  end
end

RSpec.configure { |config| config.include IntegrationHelper, :db_matrix }
