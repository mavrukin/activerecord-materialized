# frozen_string_literal: true

require "benchmark"

require "spec_helper"

RSpec.describe "refresh on dependency change" do
  let(:view_class) do
    Class.new(ActiveRecord::Materialized::View) do
      self.table_name = "mv_refresh_on_change_items"
      materialized_from -> { Item.group(:category).select("category, COUNT(*) AS item_count") }
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
    read_time = Benchmark.realtime { expect(view_class.where(category: "books").pick(:item_count)).to eq(2) }
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
