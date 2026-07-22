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

    # #131 — a widen (full_partition) on a warm view is a full recompute; route it through the atomic
    # build-and-swap, not an in-place delete_all + re-insert, so readers keep the old snapshot until an
    # instant rename instead of seeing a half-empty table.
    it "routes a warm-view full-partition widen through the atomic swap" do
      writer = ActiveRecord::Materialized::RelationCacheWriter.new(view_class)
      # Return the spy for the view's writer, but let atomic_swap!'s internal writer (for the temp
      # model) construct normally, so the real build-and-swap still runs end to end.
      allow(ActiveRecord::Materialized::RelationCacheWriter).to receive(:new).and_call_original
      allow(ActiveRecord::Materialized::RelationCacheWriter).to receive(:new).with(view_class).and_return(writer)
      allow(writer).to receive(:atomic_swap!).and_call_original
      allow(writer).to receive(:replace_partitions!).and_call_original

      Item.create!(category: "puzzles", amount: 7) # a brand-new partition the widen must pick up
      ActiveRecord::Materialized::MaintenanceStore.new(view_class).merge!(
        ActiveRecord::Materialized::MaintenanceDelta.full_partition
      )
      described_class.new(view_class).maintain!(ActiveRecord::Base.connection, view_class.table_name)

      expect(writer).to have_received(:atomic_swap!) # full recompute via build-and-swap
      expect(writer).not_to have_received(:replace_partitions!) # not the in-place delete+insert path
      expect(view_class.order(:category).pluck(:category)).to eq(%w[books games puzzles])
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
