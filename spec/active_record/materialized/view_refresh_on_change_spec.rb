# frozen_string_literal: true

require "benchmark"

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::View, ".refresh_on_change" do
  let(:view_class) do
    Class.new(ActiveRecord::Materialized::View) do
      self.table_name = "mv_refresh_on_change_items"
      materialized_from { ViewSources.item_count_by_category }
      depends_on Item
      refresh_on_change :async
      refresh_debounce 0
    end
  end

  before do
    ActiveRecord::Materialized::AsyncRefresher.reset!
    Item.delete_all
    Item.create!(category: "books", amount: 1)
    Item.create!(category: "games", amount: 2)
    view_class.refresh!
  end

  after do
    ActiveRecord::Materialized::AsyncRefresher.reset!
  end

  it "keeps reads fast while refresh runs asynchronously after writes", :aggregate_failures do
    expect(view_class.where(category: "books").pick(:item_count)).to eq(1)

    Item.create!(category: "books", amount: 5)

    expect(view_class.dirty?).to be(true)
    expect(view_class.where(category: "books").pick(:item_count)).to eq(1)

    ActiveRecord::Materialized::AsyncRefresher.flush!

    expect(view_class.dirty?).to be(false)
    expect(view_class.where(category: "books").pick(:item_count)).to eq(2)
  end

  it "serves refreshed reads quickly after async dependency writes" do
    ActiveRecord::Base.connection.execute("INSERT INTO items (category, amount) VALUES ('books', 5)")
    ActiveRecord::Materialized::AsyncRefresher.flush!

    read_time = Benchmark.realtime { view_class.where(category: "books").pick(:item_count) }
    expect(read_time).to be < 0.1
  end

  it "does not auto-refresh when strategy is manual" do
    view_class.refresh_on_change :manual
    view_class.refresh!

    Item.create!(category: "books", amount: 5)

    expect(view_class.dirty?).to be(true)
    expect(view_class.where(category: "books").pick(:item_count)).to eq(1)
  end

  it "schedules refresh after an explicit transaction commits" do
    ActiveRecord::Base.transaction do
      Item.create!(category: "books", amount: 5)
    end

    expect(view_class.dirty?).to be(true)
    expect(view_class.where(category: "books").pick(:item_count)).to eq(1)

    ActiveRecord::Materialized::AsyncRefresher.flush!
    expect(view_class.where(category: "books").pick(:item_count)).to eq(2)
  end
end
