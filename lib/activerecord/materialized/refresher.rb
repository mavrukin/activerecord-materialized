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

      sig { params(force: T::Boolean).returns(RefreshResult) }
      def refresh!(force: false)
        raise RefreshError, "#{view_class.name} is already refreshing" if metadata.refreshing? && !force

        started_at = monotonic_clock
        run_refresh_cycle(started_at, force: force)
      rescue StandardError => e
        fail_refresh!(e)
      end

      private

      sig { params(started_at: Float, force: T::Boolean).returns(RefreshResult) }
      def run_refresh_cycle(started_at, force:)
        metadata.mark_refreshing!
        view_class.run_refresh_callbacks(:before_refresh)

        row_count = perform_refresh!(force: force)
        duration_ms = elapsed_milliseconds(started_at)
        result = complete_refresh!(row_count: row_count, duration_ms: duration_ms)
        view_class.run_refresh_callbacks(:after_refresh)
        result
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

      sig { params(force: T::Boolean).returns(Integer) }
      def perform_refresh!(force: false)
        relation = view_class.resolved_source
        if force || view_class.resolved_refresh_mode == :full || !view_class.table_exists?
          return full_refresh!(relation)
        end
        return incremental_refresh! if view_class.incrementally_maintainable?

        RelationCacheWriter.new(view_class).bootstrap!(relation)
      end

      sig { params(relation: ::ActiveRecord::Relation).returns(Integer) }
      def full_refresh!(relation)
        RelationCacheWriter.new(view_class).atomic_swap!(relation)
      end

      sig { returns(Integer) }
      def incremental_refresh!
        IncrementalMaintainer.new(view_class).maintain!(view_class.connection, view_class.table_name)
      end
    end
  end
end
