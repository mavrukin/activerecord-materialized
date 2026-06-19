# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::Registry do
  after do
    described_class.send(:reset!)
  end

  it "registers materialized view subclasses" do
    view_class = Class.new(ActiveRecord::Materialized::View) do
      self.table_name = "mv_registry_test"
      materialized_from "SELECT 1 AS id"
    end

    expect(described_class.all).to include(view_class)
    expect(described_class.find(view_class.view_key)).to eq(view_class)
  end

  it "refreshes all registered views" do
    refreshed = []
    stub_refresh = ->(view_class) { view_class.define_singleton_method(:refresh!) { |**_| refreshed << name } }

    stub_refresh.call(Class.new(ActiveRecord::Materialized::View) do
      self.table_name = "mv_refresh_all_a"
      materialized_from "SELECT 1 AS value"
    end)
    stub_refresh.call(Class.new(ActiveRecord::Materialized::View) do
      self.table_name = "mv_refresh_all_b"
      materialized_from "SELECT 2 AS value"
    end)

    described_class.refresh_all!
    expect(refreshed.size).to eq(2)
  end
end
