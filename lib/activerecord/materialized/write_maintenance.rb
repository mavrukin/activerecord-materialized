# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Translates a committed dependency write into a view's pending maintenance —
    # a summary delta on a warm delta-maintainable view, otherwise a scoped (or,
    # when the partition key cannot be derived, widened) recompute — and emits the
    # maintenance instrumentation event for the path taken.
    #
    # @api private
    class WriteMaintenance
      def initialize(view_class)
        @view_class = view_class
      end

      def record!(change)
        return record_summary_delta!(change) if @view_class.delta_maintaining?
        return unless @view_class.incrementally_maintainable?

        record_scoped_recompute!(change)
      end

      private

      def record_scoped_recompute!(change)
        delta = scoped_recompute_delta(change)
        return if delta.nil? # every affected partition already applied a strictly-newer source_ts

        instrument(change, path: :scoped_recompute, partitions: delta.tracked_partition_count,
                           scope: delta.full_partition? ? :full : :scoped)
        return reset_cold_fresh_set! if cold_full_recompute?(delta)

        store.merge!(delta)
        mark_written_partitions_stale(delta)
      end

      # The affected-partition delta for a write, with provably-stale partitions suppressed by their
      # source watermark (#106) when the change carries a source_ts.
      def scoped_recompute_delta(change)
        resolver = @view_class.partition_key_resolver_for(change.table_name)
        delta = MaintenanceDeltaBuilder.new(change, @view_class.maintenance_key_columns, resolver: resolver).build
        return delta unless change.source_ts

        SourceWatermark.new(@view_class).suppress(change.source_ts, delta)
      end

      def record_summary_delta!(change)
        analysis = @view_class.aggregate_analysis
        summary = SummaryDeltaBuilder.new(change, analysis, @view_class.maintenance_key_columns).build
        return if summary.empty?

        instrument(change, path: :summary_delta, scope: :scoped, partitions: summary.tracked_partition_count)
        store.merge!(summary)
      end

      # A cold view can't apply a full-partition recompute (Refresher#maintainable? skips it), and
      # storing one would gum up the pending payload — combine() lets a full_partition absorb every
      # later scoped read-miss delta, so populate-on-read could never repopulate. So a widened recompute
      # on a cold view is dropped (not stored) and instead resets the fresh set (see {reset_cold_fresh_set!}).
      def cold_full_recompute?(delta)
        delta.full_partition? && !@view_class.materialized?
      end

      # Invalidate a cold view's entire fresh set — the scope of a widened recompute is unknown, so every
      # partition falls through to the source until a later read-miss repopulates it.
      def reset_cold_fresh_set!
        PartitionState.new(@view_class).reset!
      end

      # On a cold view the written partitions are no longer current; drop them from the fresh set until
      # re-maintained. A warm view's cache stays authoritative. A cold-view full_partition delta is
      # handled in record_scoped_recompute! (it resets the whole fresh set there), so it can't reach here.
      def mark_written_partitions_stale(delta)
        return if @view_class.materialized? || delta.full_partition?

        PartitionState.new(@view_class).mark_stale!(delta.key_tuples)
      end

      def instrument(change, path:, scope:, partitions:)
        Instrumentation.maintenance(@view_class, change: change, path: path, scope: scope, partition_count: partitions)
      end

      def store
        MaintenanceStore.new(@view_class)
      end
    end
  end
end
