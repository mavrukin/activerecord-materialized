# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::ConfigurableTableName do
  # A throwaway model whose default name comes from a mutable closure, so the dynamic resolution and
  # the explicit override can be exercised without depending on a real table.
  def model_reading(&resolver)
    Class.new(ActiveRecord::Base) do
      include ActiveRecord::Materialized::ConfigurableTableName

      configurable_table_name(&resolver)
    end
  end

  it "resolves the default dynamically on each read, and lets an explicit assignment override it" do
    name = "alpha"
    model = model_reading { name }

    expect(model.table_name).to eq("alpha") # initial, read from the configured source
    name = "beta"
    expect(model.table_name).to eq("beta")  # dynamic — re-read, so reconfiguration is reflected
    model.table_name = "explicit"
    expect(model.table_name).to eq("explicit") # an explicit override wins over the source
  end

  it "resolves the inherited default on a subclass instead of raising" do
    # The resolver is a class_attribute, so a subclass inherits it — TableModelRegistry scans all AR
    # descendants and calls .table_name on each, so a raising subclass would silently break mapping.
    child = Class.new(model_reading { "parent_table" })

    expect(child.table_name).to eq("parent_table")
  end
end
