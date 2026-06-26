# typed: strict
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
      extend T::Sig

      sig { params(view_class: ViewClass).void }
      def initialize(view_class)
        @view_class = view_class
      end

      sig { params(change: WriteChange).void }
      def record!(change)
        return record_summary_delta!(change) if @view_class.delta_maintaining?
        return unless @view_class.incrementally_maintainable?

        record_scoped_recompute!(change)
      end

      private

      sig { params(change: WriteChange).void }
      def record_scoped_recompute!(change)
        delta = MaintenanceDeltaBuilder.new(change, @view_class.maintenance_key_columns).build
        instrument(change, path: :scoped_recompute, partitions: delta.tracked_partition_count,
                           scope: delta.full_partition? ? :full : :scoped)
        store.merge!(delta)
        mark_written_partitions_stale(delta)
      end

      sig { params(change: WriteChange).void }
      def record_summary_delta!(change)
        analysis = @view_class.aggregate_analysis
        summary = SummaryDeltaBuilder.new(change, analysis, @view_class.maintenance_key_columns).build
        return if summary.empty?

        instrument(change, path: :summary_delta, scope: :scoped, partitions: summary.tracked_partition_count)
        store.merge!(summary)
      end

      # On a cold view the written partitions are no longer current; drop them from
      # the fresh set until re-maintained. A warm view's cache stays authoritative.
      sig { params(delta: MaintenanceDelta).void }
      def mark_written_partitions_stale(delta)
        return if @view_class.materialized? || delta.full_partition?

        PartitionState.new(@view_class).mark_stale!(delta.key_tuples)
      end

      sig { params(change: WriteChange, path: Symbol, scope: Symbol, partitions: Integer).void }
      def instrument(change, path:, scope:, partitions:)
        Instrumentation.maintenance(@view_class, change: change, path: path, scope: scope, partition_count: partitions)
      end

      sig { returns(MaintenanceStore) }
      def store
        MaintenanceStore.new(@view_class)
      end
    end
  end
end
