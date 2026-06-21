# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::View do
  let(:view_class) do
    Class.new(described_class) do
      self.table_name = "mv_item_counts"
      materialized_from { ViewSources.item_count_by_category }
      depends_on :items
      max_staleness 1.hour
    end
  end

  before do
    ActiveRecord::Materialized::DependencyRegistry.reset!
    Item.delete_all
    Item.create!(category: "books", amount: 1)
    Item.create!(category: "games", amount: 2)
    view_class.rebuild!(confirm: true)
  end

  it "exposes transparent ActiveRecord query interface" do
    expect(view_class.where(category: "books").pick(:item_count)).to eq(1)
    expect(view_class.count).to eq(2)
  end

  it "reports staleness based on max_staleness" do
    travel_to Time.zone.local(2026, 1, 1, 12, 0, 0) do
      view_class.rebuild!(confirm: true)
      expect(view_class.stale?).to be(false)

      travel 2.hours
      expect(view_class.stale?).to be(true)
    end
  end

  it "refreshes only when stale via refresh_if_stale!" do
    refresh_count = 0
    allow(view_class).to receive(:refresh!) do
      refresh_count += 1
      nil
    end

    view_class.refresh_if_stale!
    expect(refresh_count).to eq(0)

    travel 2.hours
    view_class.refresh_if_stale!
    expect(refresh_count).to eq(1)
  end

  it "supports callable source definitions" do
    dynamic_view = Class.new(described_class) do
      self.table_name = "mv_dynamic"
      materialized_from { ViewSources.total_item_count }
    end

    dynamic_view.rebuild!(confirm: true)
    expect(dynamic_view.pick(:total)).to eq(2)
  end
end
