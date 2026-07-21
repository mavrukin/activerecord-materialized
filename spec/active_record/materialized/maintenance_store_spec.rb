# frozen_string_literal: true

require "spec_helper"

module MaintenanceStoreHelpers
  def summary_for(category)
    ActiveRecord::Materialized::SummaryDelta.new.tap { |delta| delta.add([category], "total_amount", 1) }
  end
end

RSpec.describe ActiveRecord::Materialized::MaintenanceStore do
  include MaintenanceStoreHelpers

  subject(:store) { described_class.new(view_class) }

  let(:view_class) { define_view("mv_store_test", :sales_by_category) }

  describe "#merge!" do
    # A warm view can apply a full recompute, so combine's collapse policy persists it as usual.
    # (Only a COLD view can't apply one — that case is exercised below.)
    context "when the view is warm (a full recompute is appliable, so it is stored)" do
      before { allow(view_class).to receive(:materialized?).and_return(true) }

      it "accumulates distinct partitions below the cap" do
        allow(ActiveRecord::Materialized.configuration).to receive(:max_tracked_partitions).and_return(100)

        3.times { |i| store.merge!(summary_for("cat_#{i}")) }

        pending = store.pending
        expect(pending).to be_a(ActiveRecord::Materialized::SummaryDelta)
        expect(pending.tracked_partition_count).to eq(3)
      end

      it "collapses to a single full recompute once the cap is exceeded" do
        allow(ActiveRecord::Materialized.configuration).to receive(:max_tracked_partitions).and_return(3)

        6.times { |i| store.merge!(summary_for("cat_#{i}")) }

        pending = store.pending
        expect(pending).to be_a(ActiveRecord::Materialized::MaintenanceDelta)
        expect(pending.full_partition?).to be(true)
      end

      it "absorbs further writes once collapsed, keeping the payload bounded" do
        allow(ActiveRecord::Materialized.configuration).to receive(:max_tracked_partitions).and_return(2)

        10.times { |i| store.merge!(summary_for("cat_#{i}")) }
        payload_size = view_class.metadata.maintenance_payload.to_s.bytesize

        20.times { |i| store.merge!(summary_for("more_#{i}")) }

        expect(store.pending.full_partition?).to be(true)
        expect(view_class.metadata.maintenance_payload.to_s.bytesize).to eq(payload_size)
      end

      it "collapses an oversized scoped MaintenanceDelta the same way" do
        allow(ActiveRecord::Materialized.configuration).to receive(:max_tracked_partitions).and_return(3)

        6.times { |i| store.merge!(ActiveRecord::Materialized::MaintenanceDelta.scoped([["cat_#{i}"]])) }

        expect(store.pending.full_partition?).to be(true)
      end

      it "widens to a full recompute rather than dropping a different-kind pending delta" do
        store.merge!(summary_for("books")) # a pending summary delta from a callback write
        store.merge!(ActiveRecord::Materialized::MaintenanceDelta.scoped([["games"]])) # a reconcile repair

        # Neither the summary delta nor the scoped repair is silently dropped.
        expect(store.pending.full_partition?).to be(true)
      end

      it "stores a full recompute without touching the fresh set" do
        # A warm view is never dropped, so PartitionState (the fresh-set reset) is never consulted.
        allow(ActiveRecord::Materialized::PartitionState).to receive(:new).and_call_original

        store.merge!(ActiveRecord::Materialized::MaintenanceDelta.full_partition)

        expect(store.pending.full_partition?).to be(true)
        expect(ActiveRecord::Materialized::PartitionState).not_to have_received(:new)
      end
    end

    # #120: a full recompute is un-appliable on a cold (never-rebuilt) view — storing one lets combine's
    # terminal absorb swallow every later populate-on-read delta, so populate-on-read dies. The merge!
    # chokepoint drops it and resets the fresh set instead, covering every producer at one point.
    context "when the view is cold (a full recompute is un-appliable, so it is dropped)" do
      subject(:partitions) { ActiveRecord::Materialized::PartitionState.new(view_class) }

      it "drops a bare full recompute (mark_dirty shape) and resets the fresh set" do
        partitions.mark_fresh!([["cat_0"]], generation: partitions.current_generation) # a populated partition

        store.merge!(ActiveRecord::Materialized::MaintenanceDelta.full_partition)

        expect(store.pending).to be_nil                         # dropped, never stored
        expect(partitions.all_fresh?([["cat_0"]])).to be(false) # fresh set reset -> reads fall through
      end

      it "drops a scoped payload that overflows the cap rather than storing the collapse" do
        allow(ActiveRecord::Materialized.configuration).to receive(:max_tracked_partitions).and_return(2)
        partitions.mark_fresh!([["cat_0"]], generation: partitions.current_generation)

        # The third distinct partition pushes the merged payload past the cap; combine collapses it to a
        # full recompute inside merge! (after any per-write guard) — the chokepoint catches it here.
        3.times { |i| store.merge!(ActiveRecord::Materialized::MaintenanceDelta.scoped([["over_#{i}"]])) }

        expect(store.pending).to be_nil
        expect(partitions.all_fresh?([["cat_0"]])).to be(false)
      end

      it "heals an already-poisoned payload on the next merge! instead of absorbing into it" do
        # A pre-#120 stuck state: a full_partition already sitting in the payload.
        view_class.metadata.record_maintenance_payload!(
          ActiveRecord::Materialized::MaintenanceDelta.full_partition.serialize
        )

        store.merge!(ActiveRecord::Materialized::MaintenanceDelta.scoped([["books"]]))

        expect(store.pending).to be_nil # the poison is dropped, not kept-and-absorbing every later delta
      end
    end
  end
end
