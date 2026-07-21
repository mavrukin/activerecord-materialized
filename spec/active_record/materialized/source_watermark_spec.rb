# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::SourceWatermark do
  # An ingestion-fed view (change_source :none, immediate), so a relayed change is maintained inline.
  let(:view) { externally_fed_view("mv_watermark", immediate: true) }

  # Relay a watermarked create for a category through the ingestion API.
  def ingest(category, source_ts:)
    ActiveRecord::Materialized.ingest_change(
      table: "items", operation: :create, after: { "category" => category }, source_ts: source_ts
    )
  end

  it "suppresses a stale/out-of-order event for a partition but applies a newer one" do
    seed_items(["books", 10])
    view.rebuild!(confirm: true) # books => 1

    Item.create!(category: "books", amount: 1) # source now has 2 books
    ingest("books", source_ts: 100)
    expect(view.find_by(category: "books").item_count).to eq(2) # applied: books re-aggregated

    Item.create!(category: "books", amount: 1) # source now has 3 books...
    ingest("books", source_ts: 50)
    expect(view.find_by(category: "books").item_count).to eq(2) # ...but an older ts=50 is suppressed

    ingest("books", source_ts: 150)
    expect(view.find_by(category: "books").item_count).to eq(3) # a newer ts=150 applies again
  end

  it "applies a second distinct change sharing a coarse source_ts (an equal ts is not a redelivery)" do
    seed_items(["books", 1])
    view.rebuild!(confirm: true) # books => 1

    Item.create!(category: "books", amount: 1) # source: 2 books
    ingest("books", source_ts: 100)
    expect(view.find_by(category: "books").item_count).to eq(2) # first change at ts=100 applied

    # A second, distinct commit in the same coarse tick (e.g. MySQL's second-granular binlog ts) shares
    # source_ts=100 — it must still apply. Suppression drops only a strictly-older ts, never an equal one.
    Item.create!(category: "books", amount: 1) # source: 3 books
    ingest("books", source_ts: 100)
    expect(view.find_by(category: "books").item_count).to eq(3) # the equal-ts change is not suppressed (#118)
  end

  it "tracks watermarks per partition, so one partition's watermark can't suppress another" do
    seed_items(["books", 1], ["games", 1])
    view.rebuild!(confirm: true)
    ingest("books", source_ts: 100) # books watermark = 100

    Item.create!(category: "games", amount: 1) # source now has 2 games
    ingest("games", source_ts: 50) # ts=50 < books' 100, but games has no watermark yet

    expect(view.find_by(category: "games").item_count).to eq(2) # applied, not suppressed by books
  end

  it "reports the oldest applied partition watermark as the view's source watermark" do
    seed_items(["books", 1], ["games", 1])
    view.rebuild!(confirm: true)
    ingest("books", source_ts: 100)
    ingest("games", source_ts: 40)

    expect(view.source_watermark).to eq(40) # the most-behind partition
  end

  it "does not suppress or record a watermark when no source_ts is given" do
    seed_items(["books", 1])
    view.rebuild!(confirm: true)
    Item.create!(category: "books", amount: 1)
    ActiveRecord::Materialized.ingest_change(table: "items", operation: :create, after: { "category" => "books" })

    expect(view.find_by(category: "books").item_count).to eq(2) # applied (unchanged behavior)
    expect(view.source_watermark).to be_nil                     # nothing recorded without a watermark
  end

  it "rejects a non-Integer source_ts at the ingestion boundary" do
    expect do
      ActiveRecord::Materialized.ingest_change(
        table: "items", operation: :create, after: { "category" => "x" }, source_ts: Time.current
      )
    end.to raise_error(ArgumentError, /source_ts must be an Integer/)
  end

  it "reports nil freshness without provisioning the table (a read never runs DDL)" do
    seed_items(["books", 1])
    view.rebuild!(confirm: true)
    table = ActiveRecord::Materialized.configuration.source_watermark_table_name

    expect(view.source_watermark).to be_nil # nothing ingested with a watermark yet
    expect(ActiveRecord::Base.connection.data_source_exists?(table)).to be(false) # the read didn't CREATE it
  end
end
