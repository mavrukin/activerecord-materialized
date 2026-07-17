# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveRecord::Materialized::IncrementalMaintainer do
  let(:view_class) { define_view("mv_incremental_sales_summary", :sales_by_category) }

  before do
    seed_items(["books", 10], ["books", 5], ["games", 20])
    ActiveRecord::Materialized::Refresher.new(view_class).rebuild!
  end

  describe "#maintain!" do
    it "recomputes only the affected partition, leaving others untouched" do
      connection = ActiveRecord::Base.connection
      games_id = view_class.unscoped.find_by(category: "games").id

      Item.create!(category: "books", amount: 100)
      # Drive the recompute path directly with a scoped delta (delta-maintainable
      # views otherwise route through summary-delta IVM).
      ActiveRecord::Materialized::MaintenanceStore.new(view_class).merge!(
        ActiveRecord::Materialized::MaintenanceDelta.scoped([["books"]])
      )
      described_class.new(view_class).maintain!(connection, view_class.table_name)

      # The unaffected partition's row is preserved (not part of a full rebuild).
      expect(view_class.unscoped.find_by(category: "games").id).to eq(games_id)
      expect(view_class.order(:category).pluck(:category, :total_amount)).to eq(
        [["books", 115], ["games", 20]]
      )
    end

    # #95 — the atomic consume returns nil to a cross-process loser (a concurrent cycle already
    # consumed the scoped delta). maintain! must no-op and report the cache's real row count, not 0.
    it "no-ops and reports the current row count when another cycle already consumed the delta" do
      row_count = view_class.unscoped.count # rebuilt above => books + games => 2 partitions
      store = ActiveRecord::Materialized::MaintenanceStore.new(view_class)
      allow(store).to receive(:consume_pending_delta!).and_return(nil) # the winner already took it
      allow(ActiveRecord::Materialized::MaintenanceStore).to receive(:new).with(view_class).and_return(store)

      result = described_class.new(view_class).maintain!(ActiveRecord::Base.connection, view_class.table_name)

      expect(result).to eq(row_count) # the true total, never 0 — which would clobber metadata.row_count
    end
  end
end
