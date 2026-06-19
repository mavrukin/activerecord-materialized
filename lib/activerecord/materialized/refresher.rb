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

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        metadata.mark_refreshing!
        view_class.run_refresh_callbacks(:before_refresh)

        row_count = perform_refresh!(force: force)

        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
        metadata.mark_refreshed!(row_count: row_count, duration_ms: duration_ms)
        view_class.run_refresh_callbacks(:after_refresh)

        RefreshResult.new(
          view_class: view_class,
          row_count: row_count,
          duration_ms: duration_ms,
          refreshed_at: metadata.last_refreshed_at
        )
      rescue StandardError => e
        metadata.mark_failed!(e)
        raise RefreshError, "Failed to refresh #{view_class.name}: #{e.message}", e.backtrace
      end

      private

      sig { returns(Metadata) }
      def metadata
        @metadata ||= view_class.metadata
      end

      sig { params(force: T::Boolean).returns(Integer) }
      def perform_refresh!(force: false)
        relation = view_class.resolved_source

        if force || view_class.resolved_refresh_mode == :full || !view_class.table_exists?
          RelationCacheWriter.new(view_class).atomic_swap!(relation)
        elsif view_class.incrementally_maintainable?
          IncrementalMaintainer.new(view_class).maintain!(view_class.connection, view_class.table_name)
        else
          RelationCacheWriter.new(view_class).bootstrap!(relation)
        end
      end
    end
  end
end
