# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::View, ".refresh_on_change" do
  let(:view_class) do
    define_view("mv_refresh_on_change_items", :item_count_by_category) do
      depends_on Item
      refresh_on_change :async
    end
  end

  before do
    ActiveRecord::Materialized::AsyncRefresher.reset!
    # Accumulate enqueued refreshes and run them only on flush!, so the
    # dirty/stale assertions don't race a background timer.
    ActiveRecord::Materialized::AsyncRefresher.paused = true
    seed_items(["books", 1], ["games", 2])
    view_class.rebuild!(confirm: true)
  end

  after do
    ActiveRecord::Materialized::AsyncRefresher.paused = false
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

  it "keeps serving from the warm cache across async maintenance" do
    Item.create!(category: "books", amount: 5)
    ActiveRecord::Materialized::AsyncRefresher.flush!

    # Still materialized, so reads hit the cache (not read-through) and reflect
    # the maintained value.
    expect(view_class.materialized?).to be(true)
    expect(view_class.where(category: "books").pick(:item_count)).to eq(2)
  end

  it "does not auto-refresh when strategy is manual" do
    view_class.refresh_on_change :manual

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
