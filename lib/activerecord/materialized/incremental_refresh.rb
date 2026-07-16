# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Runs one incremental-maintenance pass for a view, choosing the summary-delta
    # or scoped-recompute path from the pending maintenance and annotating the
    # refresh instrumentation payload with the mode and partitions it touched.
    #
    # @api private
    class IncrementalRefresh
      def initialize(view_class, payload)
        @view_class = view_class
        @payload = payload
      end

      def call
        ensure_cache_table!
        store = MaintenanceStore.new(@view_class)
        pending = store.pending
        @payload[:mode] = mode(pending)
        @payload[:partition_count] = partition_count(pending)
        apply!(store, pending)
      end

      private

      def apply!(store, pending)
        if pending.is_a?(SummaryDelta)
          # Consume+apply the additive delta under a row lock so concurrent cross-process cycles
          # can't apply it twice; a loser finds an empty payload and no-ops. The row count is read
          # after the lock releases (keeping the full-table COUNT out of the critical section) and
          # reflects the cache's true total for winner and loser alike — never 0, which would
          # clobber a populated view's row_count. The scoped path below is idempotent under
          # serialized execution; a concurrent double-run is wasteful and, on Postgres, can
          # duplicate a brand-new partition's rows — a known scoped-path gap tracked in #95.
          store.with_consumed_summary_delta { |delta| DeltaMaintainer.new(@view_class).apply!(delta) }
          return @view_class.unscoped.count
        end

        IncrementalMaintainer.new(@view_class).maintain!(@view_class.connection, @view_class.table_name)
      end

      def mode(pending)
        pending.is_a?(SummaryDelta) ? :summary_delta : :scoped_recompute
      end

      # Partitions this pass recomputes; nil when it widened to a full recompute.
      def partition_count(pending)
        return pending.tracked_partition_count if pending.is_a?(SummaryDelta)
        return nil unless pending.is_a?(MaintenanceDelta)

        pending.full_partition? ? nil : pending.key_tuples.size
      end

      # Cheap DDL so partition maintenance has somewhere to write — never a populate.
      def ensure_cache_table!
        return if @view_class.table_exists?

        CacheTableSchema.ensure_table!(@view_class, @view_class.resolved_source)
      end
    end
  end
end
