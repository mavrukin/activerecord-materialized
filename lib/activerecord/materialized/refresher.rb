# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class Refresher
      extend T::Sig

      class RefreshError < StandardError; end

      sig { returns(ViewClass) }
      attr_reader :view_class

      sig { params(view_class: ViewClass).void }
      def initialize(view_class)
        @view_class = view_class
        @metadata = T.let(nil, T.nilable(Metadata))
      end

      # Full materialization — the only path that scans all base data.
      sig { returns(RefreshResult) }
      def rebuild!
        run_cycle(-> { perform_rebuild! })
      rescue StandardError => e
        fail_refresh!(e)
      end

      # Incremental maintenance only; a no-op when the view is not maintainable.
      sig { returns(RefreshResult) }
      def refresh!
        return RefreshResult.skipped(view_class) unless maintainable?

        run_cycle(-> { incremental_refresh! })
      rescue StandardError => e
        fail_refresh!(e)
      end

      private

      sig { returns(T::Boolean) }
      def maintainable?
        return false unless view_class.incrementally_maintainable?

        pending = MaintenanceStore.new(view_class).pending
        return false if pending.nil?

        # Never full-populate a cold view from maintenance — reads fall through
        # to the source instead. Scoped deltas populate just their partitions.
        return false if !view_class.materialized? && pending.is_a?(MaintenanceDelta) && pending.full_partition?

        true
      end

      sig { params(operation: T.proc.returns(Integer)).returns(RefreshResult) }
      def run_cycle(operation)
        raise RefreshError, "#{view_class.name} is already refreshing" if metadata.refreshing?

        started_at = monotonic_clock
        metadata.mark_refreshing!
        view_class.run_refresh_callbacks(:before_refresh)

        row_count = operation.call
        result = complete_refresh!(row_count: row_count, duration_ms: elapsed_milliseconds(started_at))
        view_class.run_refresh_callbacks(:after_refresh)
        result
      end

      sig { returns(Integer) }
      def perform_rebuild!
        row_count = RelationCacheWriter.new(view_class).atomic_swap!(view_class.resolved_source)
        metadata.mark_warm!
        # Fully materialized now, so the cold-view partition exceptions no longer apply.
        PartitionState.new(view_class).reset!
        row_count
      end

      sig { returns(Integer) }
      def incremental_refresh!
        ensure_cache_table!

        store = MaintenanceStore.new(view_class)
        pending = store.pending
        return apply_summary_delta!(store, pending) if pending.is_a?(SummaryDelta)

        IncrementalMaintainer.new(view_class).maintain!(view_class.connection, view_class.table_name)
      end

      # Cheap DDL so partition maintenance has somewhere to write — never a populate.
      sig { void }
      def ensure_cache_table!
        return if view_class.table_exists?

        CacheTableSchema.ensure_table!(view_class, view_class.resolved_source)
      end

      sig { params(store: MaintenanceStore, summary: SummaryDelta).returns(Integer) }
      def apply_summary_delta!(store, summary)
        store.clear!
        DeltaMaintainer.new(view_class).apply!(summary)
      end

      sig { params(error: StandardError).returns(T.noreturn) }
      def fail_refresh!(error)
        metadata.mark_failed!(error)
        raise RefreshError, "Failed to refresh #{view_class.name}: #{error.message}", error.backtrace
      end

      sig { returns(Metadata) }
      def metadata
        @metadata ||= view_class.metadata
      end

      sig { returns(Float) }
      def monotonic_clock
        T.cast(Process.clock_gettime(Process::CLOCK_MONOTONIC), Float)
      end

      sig { params(started_at: Float).returns(Integer) }
      def elapsed_milliseconds(started_at)
        ((monotonic_clock - started_at) * 1000).round
      end

      sig { params(row_count: Integer, duration_ms: Integer).returns(RefreshResult) }
      def complete_refresh!(row_count:, duration_ms:)
        metadata.mark_refreshed!(row_count: row_count, duration_ms: duration_ms)
        RefreshResult.new(
          view_class: view_class,
          row_count: row_count,
          duration_ms: duration_ms,
          refreshed_at: metadata.last_refreshed_at
        )
      end
    end
  end
end
