# frozen_string_literal: true

require "spec_helper"
require_relative "../../benchmark/support/cdc_scenario"

# #71 — the reusable CDC-with-raw-writes scenario harness that the demo visualizes
# and the real-DB integration suite (#70) reuses. It issues a write that bypasses
# ActiveRecord (so no callback fires), relays it through
# ActiveRecord::Materialized.ingest_change, and asserts the view converges via
# SCOPED maintenance — all observed through the gem's real instrumentation events.
RSpec.describe BenchmarkSupport::CdcScenario, :integration do
  let(:view) { externally_fed_view("mv_cdc_scenario", immediate: true) }

  before do
    seed_items(["books", 1], ["games", 1]) # one item each => item_count 1 per category
    view.rebuild!(confirm: true)
  end

  it "captures a raw write, relays it, and confirms scoped convergence via real events" do
    run = described_class.new(view: view, raw_write: lambda {
      Item.connection.execute("INSERT INTO items (category, amount) VALUES ('books', 5)")
      { table: "items", operation: :create, key_attributes: { "category" => "books" } }
    }).run

    # The cache converged to what the source now produces...
    expect(run.converged?).to be(true)
    expect(view.where(category: "books").pick(:item_count)).to eq(2)
    # ...via scoped maintenance (not a full rebuild)...
    expect(run.scoped?).to be(true)
    # ...and the engine's real maintenance event was captured in the timeline.
    maintenance = run.timeline.find { |event| event.stage == :maintenance }
    expect(maintenance.payload).to include(scope: :scoped)
    expect(run.descriptor).to include(table: "items", operation: :create)
  end

  it "leaves the view stale when a raw write is not relayed (no callback fires)" do
    Item.connection.execute("INSERT INTO items (category, amount) VALUES ('games', 9)")

    expect(Item.where(category: "games").count).to eq(2) # the source grew
    expect(view.where(category: "games").pick(:item_count)).to eq(1) # but the CDC-fed view is untouched
  end
end
