# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::PartitionState do
  subject(:partitions) { described_class.new(view_class) }

  let(:view_class) do
    define_view("mv_partition_items", :item_count_by_category) { refresh_on_change :manual }
  end

  let(:record_create) do
    ->(item) { view_class.record_write_change!(write_change(item, :create)) }
  end

  before do
    ActiveRecord::Materialized::DependencyRegistry.reset!
    seed_items(["books", 1], ["books", 2], ["games", 3])
  end

  describe ".keys_from" do
    it "extracts a single-column partition tuple" do
      expect(described_class.keys_from(view_class, [{ category: "books" }])).to eq([["books"]])
    end

    it "expands IN conditions into one tuple per value" do
      expect(described_class.keys_from(view_class, [{ category: %w[books games] }]))
        .to eq([["books"], ["games"]])
    end

    it "returns nil for non-key or non-hash conditions" do
      expect(described_class.keys_from(view_class, ["item_count > ?", 1])).to be_nil
      expect(described_class.keys_from(view_class, [{ category: "books", extra: 1 }])).to be_nil
    end
  end

  it "serves a cold keyed read through the source without materializing" do
    expect(view_class.materialized?).to be(false)
    expect(partitions.all_fresh?([["books"]])).to be(false)

    expect(view_class.where(category: "books").pick(:item_count)).to eq(2)
    expect(partitions.all_fresh?([["books"]])).to be(false)
    expect(view_class.materialized?).to be(false)
  end

  it "materializes the touched partition so the next keyed read is served from the cache" do
    view_class.where(category: "books").to_a # read-miss enqueues maintenance
    view_class.refresh!                      # processes the enqueued partition delta

    expect(partitions.all_fresh?([["books"]])).to be(true)
    expect(partitions.all_fresh?([["games"]])).to be(false)
    expect(view_class.materialized?).to be(false) # still cold overall (partial)
    expect(view_class.where(category: "books").pick(:item_count)).to eq(2)
  end

  it "reflects all data on an unkeyed read while only some partitions are fresh" do
    view_class.where(category: "books").to_a
    view_class.refresh!
    Item.create!(category: "tools", amount: 9)

    expect(view_class.count).to eq(3) # books, games, tools via read-through
  end

  it "populates a written partition so a cold view shows the update fast (the win)" do
    record_create.call(Item.create!(category: "books", amount: 10))
    view_class.refresh!

    expect(partitions.all_fresh?([["books"]])).to be(true)
    expect(view_class.where(category: "books").pick(:item_count)).to eq(3)
  end

  it "marks a fresh partition stale on a later write" do
    view_class.where(category: "books").to_a
    view_class.refresh!
    expect(partitions.all_fresh?([["books"]])).to be(true)

    record_create.call(Item.create!(category: "books", amount: 7))
    expect(partitions.all_fresh?([["books"]])).to be(false)
  end

  # #120: reset! (a widen invalidation) advances a per-view epoch; a populate stamps the epoch it
  # captured before its source read, and all_fresh? honours only current-epoch marks. So a populate
  # that raced a widen (captured the pre-widen epoch, landed after the reset) is never served stale.
  it "ignores a populate stamped with a superseded generation, then serves a re-populate" do
    stale_generation = partitions.current_generation # a populate captures the epoch before its source read
    partitions.reset!                                # a widen invalidates the whole fresh set, advancing the epoch
    partitions.mark_fresh!([["books"]], generation: stale_generation) # the stale populate lands after the reset

    # The mark reflects pre-widen data, so it is not served from cache.
    expect(partitions.all_fresh?([["books"]])).to be(false)

    # A populate that captured the current epoch is served normally.
    partitions.mark_fresh!([["books"]], generation: partitions.current_generation)
    expect(partitions.all_fresh?([["books"]])).to be(true)
  end

  it "clears partition exceptions on rebuild!" do
    view_class.where(category: "books").to_a
    view_class.refresh!
    view_class.rebuild!(confirm: true)

    expect(view_class.materialized?).to be(true)
    expect(ActiveRecord::Materialized::PartitionRecord.where(view_name: view_class.view_key).count).to eq(0)
  end
end
