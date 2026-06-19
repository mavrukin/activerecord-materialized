# frozen_string_literal: true

require "spec_helper"

module RegistrySpecHelpers
  module_function

  def register_refresh_all_views!(refreshed)
    Class.new(ActiveRecord::Materialized::View) do
      self.table_name = "mv_refresh_all_a"
      materialized_from { ViewSources.item_id_sample }
      define_singleton_method(:refresh!) do |**_|
        refreshed << name
        nil
      end
    end

    Class.new(ActiveRecord::Materialized::View) do
      self.table_name = "mv_refresh_all_b"
      materialized_from { ViewSources.item_amount_sample }
      define_singleton_method(:refresh!) do |**_|
        refreshed << name
        nil
      end
    end
  end
end

RSpec.describe ActiveRecord::Materialized::Registry do
  after do
    described_class.send(:reset!)
  end

  it "registers materialized view subclasses" do
    view_class = Class.new(ActiveRecord::Materialized::View) do
      self.table_name = "mv_registry_test"
      materialized_from { ViewSources.item_id_sample }
    end

    expect(described_class.all).to include(view_class)
    expect(described_class.find(view_class.view_key)).to eq(view_class)
  end

  it "refreshes all registered views" do
    refreshed = []
    RegistrySpecHelpers.register_refresh_all_views!(refreshed)

    described_class.refresh_all!
    expect(refreshed.size).to eq(2)
  end
end
