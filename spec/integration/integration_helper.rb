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

  # Establish + provision for a profile, but FAIL (not skip) an ARM_ONLY-targeted
  # adapter that is unreachable, so a green per-adapter CI job always means the
  # engine was actually exercised.
  def with_adapter!(profile)
    unless profile.available?
      reason = "#{profile.label} unavailable — #{profile.unavailable_reason}"
      raise reason if profile.required?

      skip(reason)
    end
    establish_adapter!(profile)
  end

  def seed_line_items(*rows)
    IntegrationSchema::LineItem.delete_all
    rows.each { |category, amount| IntegrationSchema::LineItem.create!(category: category, amount: amount) }
  end

  # Relay an out-of-band write to a dependency table through the CDC ingestion API.
  def relay(table, operation, **payload)
    ActiveRecord::Materialized.ingest_change(table: table, operation: operation, **payload)
  end

  # True when the view's cache equals what its source relation would produce now.
  def converged?(view)
    BenchmarkSupport::ResultComparison.equivalent?(view.unscoped.to_a, view.resolved_source.to_a)
  end
end

RSpec.configure { |config| config.include IntegrationHelper, :db_matrix }
