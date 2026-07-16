# frozen_string_literal: true

require "spec_helper"

# #64 — self-healing reconciliation: verify a view's contents against its source
# (via #62's DataVerifier) and repair whatever the change source missed, using
# SCOPED maintenance rather than a full rebuild. Drift is simulated by mutating the
# cache out-of-band through the cache model, standing in for a write the change
# source never observed.
RSpec.describe ActiveRecord::Materialized::Reconciler do
  let(:view) { define_view("mv_reconcile_items", :item_count_by_category) }

  before do
    seed_items(["books", 5], ["games", 3], ["toys", 2]) # one item each => item_count 1 per category
    view.rebuild!(confirm: true)
  end

  it "repairs a drifted partition with scoped maintenance, never a full rebuild" do
    view.unscoped.find_by(category: "books").update!(item_count: 999) # a write the change source missed

    result = nil
    refresh_events = capture_events("refresh.active_record_materialized") { result = view.reconcile!(mode: :full) }

    # The drifted partition is repaired back to the source's value...
    expect(view.unscoped.find_by(category: "books").item_count).to eq(1)
    # ...and siblings are untouched (a full rebuild is not what happened here)...
    expect(view.unscoped.where(category: %w[games toys]).pluck(:item_count)).to eq([1, 1])
    # ...via a scoped recompute of exactly the one partition, not a :full pass.
    repair = refresh_events.map(&:payload).find { |p| p[:mode] == :scoped_recompute }
    expect(repair[:partition_count]).to eq(1)
    expect(refresh_events.map { |event| event.payload[:mode] }).not_to include(:full)
    expect(result.repaired_keys).to contain_exactly(["books"])
  end

  it "records a reconciliation on a consistent view without repairing anything" do
    expect(view.metadata.record.last_reconciled_at).to be_nil

    result = view.reconcile!(mode: :full)

    expect(result.repaired?).to be(false)
    expect(result.repaired_partition_count).to eq(0)
    expect(view.metadata.record.last_reconciled_at).not_to be_nil # staleness clock reset even with no repair
    expect(view.metadata.record.reconciled_partition_count).to eq(0)
  end

  it "re-inserts a missing partition and removes an extra one" do
    view.unscoped.find_by(category: "toys").destroy! # source has it, cache lost it (missing)
    view.create!(category: "ghost", item_count: 7)   # cache only, source lacks it (extra)

    result = view.reconcile!(mode: :full)

    expect(view.unscoped.find_by(category: "toys").item_count).to eq(1) # re-aggregated from source
    expect(view.unscoped.find_by(category: "ghost")).to be_nil          # 0 source rows => removed
    expect(result.repaired_keys).to contain_exactly(["toys"], ["ghost"])
  end

  it "defers under a live refresh without corrupting its guard, and the repair is durable" do
    view.unscoped.find_by(category: "books").update!(item_count: 999)

    # Simulate another server owning the cycle lock: while it is live, a refresh that has
    # maintenance to apply can't acquire the lock and defers (the real cross-process lock is
    # exercised end to end in the concurrency integration spec). The drain-refresh has nothing
    # pending, so it still runs; only the queued repair defers.
    store = ActiveRecord::Materialized::MaintenanceStore.new(view)
    live = true
    allow(view).to receive(:refresh!).and_wrap_original do |original, *args|
      raise ActiveRecord::Materialized::Refresher::AlreadyRefreshingError if live && store.pending

      original.call(*args)
    end

    result = view.reconcile!(mode: :full)

    expect(result.deferred).to be(true)
    expect(view.metadata.record.last_reconciled_at).to be_nil # not marked reconciled on a defer
    expect(view.metadata.record.last_error).to be_nil # and the view is not marked failed
    # ...and the scoped repair is queued, so a later refresh drains it — nothing is lost.
    expect(store.pending.key_tuples).to contain_exactly(["books"])

    live = false # the live cycle finishes
    view.refresh!
    expect(view.unscoped.find_by(category: "books").item_count).to eq(1) # repaired on the next cycle
  end

  it "reconcile_stale! reconciles only stale views" do
    # Freshly rebuilt, not dirty, no max_staleness => not stale => skipped.
    expect(view.stale?).to be(false)
    expect(ActiveRecord::Materialized.reconcile_stale!(mode: :full)).to eq([])

    view.metadata.mark_dirty! # dirty => stale => reconciled
    results = ActiveRecord::Materialized.reconcile_stale!(mode: :full)

    expect(results.map(&:view_name)).to eq([view.view_key])
  end

  it "clears time-based staleness after a clean reconcile" do
    aging = define_view("mv_reconcile_aging", :item_count_by_category) { max_staleness 1.hour }
    aging.rebuild!(confirm: true)
    aging.metadata.record.update!(last_refreshed_at: 2.hours.ago) # stale by time, though drift-free
    expect(aging.stale?).to be(true)

    aging.reconcile!(mode: :full)

    expect(aging.stale?).to be(false) # reconcile verified it clean, so the staleness clock resets
  end

  it "skips a cold, never-materialized view without stamping it reconciled" do
    cold = define_view("mv_reconcile_cold", :item_count_by_category) # never rebuilt => read-through

    result = cold.reconcile!(mode: :full)

    expect(result.repaired?).to be(false)
    expect(cold.metadata.record.last_reconciled_at).to be_nil # not falsely marked healthy
  end

  it "isolates a failing view so reconcile_stale! still reconciles the rest of the fleet" do
    broken = define_view("mv_reconcile_broken", :item_count_by_category)
    broken.rebuild!(confirm: true)
    view.metadata.mark_dirty! # both stale
    broken.metadata.mark_dirty!
    allow(broken).to receive(:reconcile!).and_raise("boom")

    results = ActiveRecord::Materialized.reconcile_stale!(mode: :full)

    expect(results.find { |result| result.view_name == view.view_key }.failed?).to be(false)
    expect(results.find { |result| result.view_name == broken.view_key })
      .to have_attributes(failed?: true, error: "boom")
  end
end
