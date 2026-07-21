# frozen_string_literal: true

require "spec_helper"

# #63 — maintenance driven from a CDC / external change stream. A consumer relays
# normalized change descriptors to ActiveRecord::Materialized.ingest_change; the
# view is callback-free (change_source :none) and recomputes affected partitions,
# so at-least-once / out-of-order delivery converges. No callbacks are installed.
# The view never observes the underlying writes itself (its callbacks are
# filtered), so an Item.create! / update! stands in for an out-of-band write.
module CdcIngestion
end

RSpec.describe CdcIngestion, :integration do
  # Move `mover` into `into` in the source and relay it as a non-FULL CDC update whose before-image
  # carries only the primary key (no group key) — the case where the old partition can't be derived,
  # so maintenance must widen to a full recompute (Postgres default REPLICA IDENTITY / MySQL minimal).
  def relay_pk_only_move(mover, into)
    mover.update!(category: into)
    ActiveRecord::Materialized.ingest_change(
      table: "items", operation: :update, before: { "id" => mover.id }, after: { "category" => into }
    )
  end

  it "keeps an externally-fed view correct from a stream of change descriptors" do
    view = externally_fed_view("mv_cdc_stream", immediate: true)
    Item.create!(category: "books", amount: 1) # unobserved by the :none view
    view.rebuild!(confirm: true) # cache: books=1 (item_count inferred as integer)
    expect(view.where(category: "books").pick(:item_count)).to eq(1)

    Item.create!(category: "books", amount: 5)
    ActiveRecord::Materialized.ingest_change(table: "items", operation: :create, after: { "category" => "books" })

    expect(view.where(category: "books").pick(:item_count)).to eq(2)
  end

  it "recomputes both partitions when an update moves a row across partitions" do
    view = externally_fed_view("mv_cdc_move", immediate: true)
    mover = Item.create!(category: "books", amount: 1)
    Item.create!(category: "books", amount: 2)
    view.rebuild!(confirm: true) # books=2
    expect(view.where(category: "books").pick(:item_count)).to eq(2)

    mover.update!(category: "toys") # books -> toys, relayed with full before/after images
    ActiveRecord::Materialized.ingest_change(
      table: "items", operation: :update, before: { "category" => "books" }, after: { "category" => "toys" }
    )

    expect(view.where(category: "books").pick(:item_count)).to eq(1) # old partition recomputed
    expect(view.where(category: "toys").pick(:item_count)).to eq(1)  # new partition recomputed
  end

  it "widens an update to a full recompute when only a partial image is available" do
    view = externally_fed_view("mv_cdc_partial", immediate: true)
    mover = Item.create!(category: "books", amount: 1)
    Item.create!(category: "toys", amount: 1)
    view.rebuild!(confirm: true) # books=1, toys=1
    expect(view.where(category: "books").pick(:item_count)).to eq(1)

    mover.update!(category: "toys") # move, but the stream carries only the after-image
    ActiveRecord::Materialized.ingest_change(table: "items", operation: :update, after: { "category" => "toys" })

    expect(view.where(category: "books").pick(:item_count)).to be_nil # old partition recomputed away, not left stale
    expect(view.where(category: "toys").pick(:item_count)).to eq(2)
  end

  it "widens a partition-moving update whose before-image lacks the group key (PK-only image)" do
    view = externally_fed_view("mv_cdc_pk_only", immediate: true)
    mover = Item.create!(category: "books", amount: 1)
    Item.create!(category: "toys", amount: 1)
    view.rebuild!(confirm: true) # books=1, toys=1
    expect(view.where(category: "books").pick(:item_count)).to eq(1)

    # The old partition can't be derived from the PK-only before-image, so maintenance must widen to a
    # full recompute rather than scope to only the (derivable) new partition — otherwise 'books' is stale.
    relay_pk_only_move(mover, "toys")

    expect(view.where(category: "books").pick(:item_count)).to be_nil # old partition recomputed away, not left stale
    expect(view.where(category: "toys").pick(:item_count)).to eq(2)
  end

  it "invalidates a cold view's fresh partition on a widening update, and the cache still recovers" do
    view = externally_fed_view("mv_cdc_cold_widen") # cold: never rebuilt, async default
    mover = Item.create!(category: "books", amount: 1)
    Item.create!(category: "toys", amount: 1)
    view.where(category: "toys").to_a # read-miss enqueues maintenance for 'toys'...
    view.refresh!                     # ...which populates it and marks it fresh (cache toys=1)
    expect(view.where(category: "toys").pick(:item_count)).to eq(1) # served from the fresh cache

    # Move a row INTO toys, relayed with a non-FULL (PK-only) before-image. The old partition can't be
    # named, so maintenance widens to a full recompute — which a cold view can't apply. The fresh 'toys'
    # partition is dropped (or it serves the stale 1), and the un-appliable delta is NOT stored (or it
    # would gum up the pending payload and block populate-on-read from ever repopulating the cache).
    relay_pk_only_move(mover, "toys") # source: toys now has 2
    expect(view.where(category: "toys").pick(:item_count)).to eq(2) # read-through to source, not the stale cache

    # Populate-on-read still recovers: a later read + refresh repopulates 'toys' into the cache (it would
    # not if the widen had left a full_partition payload stuck in the store, absorbing this read-miss).
    view.where(category: "toys").to_a
    view.refresh!
    expect(ActiveRecord::Materialized::PartitionState.new(view).all_fresh?([["toys"]])).to be(true)
  end

  it "scopes maintenance to the partition named by key_attributes" do
    view = externally_fed_view("mv_cdc_keys", immediate: true)
    Item.create!(category: "books", amount: 1)
    Item.create!(category: "toys", amount: 1)
    view.rebuild!(confirm: true) # books=1, toys=1

    Item.create!(category: "books", amount: 2) # both partitions grow out-of-band...
    Item.create!(category: "toys", amount: 2)
    ActiveRecord::Materialized.ingest_change(
      table: "items", operation: :create, key_attributes: { "category" => "books" }
    )

    expect(view.where(category: "books").pick(:item_count)).to eq(2) # ...but only books is ingested
    expect(view.where(category: "toys").pick(:item_count)).to eq(1)  # toys NOT recomputed — scoped
  end

  it "converges under duplicate and out-of-order descriptor delivery" do
    view = externally_fed_view("mv_cdc_idem", immediate: true)
    Item.create!(category: "books", amount: 1)
    view.rebuild!(confirm: true)

    Item.create!(category: "books", amount: 2)
    # An update and a duplicate create for the same key, delivered out of order.
    ActiveRecord::Materialized.ingest_change(
      table: "items", operation: :update, key_attributes: { "category" => "books" }
    )
    ActiveRecord::Materialized.ingest_change(
      table: "items", operation: :create, key_attributes: { "category" => "books" }
    )

    expect(view.where(category: "books").pick(:item_count)).to eq(2) # not 3 or 4
  end

  it "installs no commit callbacks when maintenance is CDC-driven" do
    allow(ActiveRecord::Materialized::DependencyTrackable).to receive(:subscribe).and_call_original

    externally_fed_view("mv_cdc_no_cb")

    expect(ActiveRecord::Materialized::DependencyTrackable).not_to have_received(:subscribe)
  end
end
