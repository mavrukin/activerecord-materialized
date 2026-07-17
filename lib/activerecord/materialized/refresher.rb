# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Orchestrates explicit rebuilds and incremental maintenance for a single view.
    #
    # @api private
    class Refresher
      # Raised when a refresh or rebuild fails.
      class RefreshError < StandardError; end

      # Raised when a cycle can't start because another is already running for the
      # view. A subclass of {RefreshError} so existing rescues still catch it, but
      # distinct so a caller (reconciliation) can treat an overlap as a benign,
      # retryable defer — and so it is re-raised without {#fail_refresh!}, which would
      # otherwise mark the view failed and clear the *live* cycle's `refreshing` guard.
      class AlreadyRefreshingError < RefreshError; end

      attr_reader :view_class

      def initialize(view_class)
        @view_class = view_class
        @metadata = nil
      end

      # Full materialization — the only path that scans all base data.
      def rebuild!
        guarded_maintenance do
          Instrumentation.refresh(view_class, operation: :rebuild) do |payload|
            payload[:mode] = :full
            run_cycle(-> { perform_rebuild! })
          end
        end
      end

      # Incremental maintenance only; a no-op when the view is not maintainable.
      def refresh!
        guarded_maintenance do
          Instrumentation.refresh(view_class, operation: :incremental) do |payload|
            next RefreshResult.skipped(view_class) unless maintainable?

            run_cycle(-> { IncrementalRefresh.new(view_class, payload).call })
          end
        end
      end

      private

      # Runs a maintenance cycle under the configured writer role, translating an overlap into a
      # benign re-raise (a live cycle owns the guard) and any other failure into fail_refresh!. The
      # rescue lives inside the routed connection so fail_refresh!'s write also lands on the writer.
      def guarded_maintenance
        ConnectionRouting.maintenance do
          yield
        rescue AlreadyRefreshingError
          raise # a live cycle owns the guard; don't fail_refresh! it (that would clear the guard)
        rescue StandardError => e
          fail_refresh!(e)
        end
      end

      def maintainable?
        return false unless view_class.incrementally_maintainable?

        pending = MaintenanceStore.new(view_class).pending
        return false if pending.nil?

        # Never full-populate a cold view from maintenance — reads fall through
        # to the source instead. Scoped deltas populate just their partitions.
        return false if !view_class.materialized? && pending.is_a?(MaintenanceDelta) && pending.full_partition?

        true
      end

      def run_cycle(operation)
        raise AlreadyRefreshingError, "#{view_class.name} is already refreshing" if metadata.refreshing?

        started_at = monotonic_clock
        metadata.mark_refreshing!
        view_class.run_refresh_callbacks(:before_refresh)

        row_count = operation.call
        result = complete_refresh!(row_count: row_count, duration_ms: elapsed_milliseconds(started_at))
        view_class.run_refresh_callbacks(:after_refresh)
        result
      end

      def perform_rebuild!
        row_count = RelationCacheWriter.new(view_class).atomic_swap!(view_class.resolved_source)
        metadata.mark_warm!
        # Fully materialized now, so the cold-view partition exceptions no longer apply.
        PartitionState.new(view_class).reset!
        row_count
      end

      def fail_refresh!(error)
        metadata.mark_failed!(error)
        raise RefreshError, "Failed to refresh #{view_class.name}: #{error.message}", error.backtrace
      end

      def metadata
        @metadata ||= view_class.metadata
      end

      def monotonic_clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def elapsed_milliseconds(started_at)
        ((monotonic_clock - started_at) * 1000).round
      end

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
