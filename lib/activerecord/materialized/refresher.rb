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

      # Explicit, intentional full materialization. This is the only path that
      # scans all base data, so callers (Klass.rebuild!, warm-up) opt in
      # deliberately — it is never triggered by a read or by background
      # maintenance.
      sig { returns(RefreshResult) }
      def rebuild!
        run_cycle(-> { perform_rebuild! })
      rescue StandardError => e
        fail_refresh!(e)
      end

      # Incremental maintenance only. Never builds a cold view and never scans
      # all base data; a no-op when the view is not warm or not incrementally
      # maintainable. Used by the read and background-maintenance paths.
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

        delta = MaintenanceStore.new(view_class).pending_delta
        return false if delta.nil?

        # Never full-populate a cold view from maintenance — reads fall through
        # to the source instead. Scoped deltas populate just their partitions.
        return false if !view_class.materialized? && delta.full_partition?

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
        # Now fully materialized: the cold-view partition exceptions no longer
        # apply.
        PartitionState.new(view_class).reset!
        row_count
      end

      sig { returns(Integer) }
      def incremental_refresh!
        # A cold view may not have a cache table yet; partition maintenance needs
        # somewhere to write. Cheap DDL only — never a full populate.
        CacheTableSchema.ensure_table!(view_class, view_class.resolved_source) unless view_class.table_exists?

        IncrementalMaintainer.new(view_class).maintain!(view_class.connection, view_class.table_name)
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
