# typed: strict
# frozen_string_literal: true

require_relative "refresher/strategies"

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
        @quoter = T.let(TableQuoter.new(view_class), TableQuoter)
      end

      sig { params(force: T::Boolean).returns(RefreshResult) }
      def refresh!(force: false)
        raise RefreshError, "#{view_class.name} is already refreshing" if metadata.refreshing? && !force

        started_at = monotonic_clock
        run_refresh_cycle(started_at)
      rescue StandardError => e
        fail_refresh!(e)
      end

      private

      sig { returns(TableQuoter) }
      attr_reader :quoter

      sig { params(started_at: Float).returns(RefreshResult) }
      def run_refresh_cycle(started_at)
        metadata.mark_refreshing!
        view_class.run_refresh_callbacks(:before_refresh)

        row_count = perform_refresh!
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

      sig { returns(Integer) }
      def perform_refresh!
        connection = view_class.connection
        source_sql = view_class.resolved_source_sql
        table_name = view_class.table_name

        if ::ActiveRecord::Materialized.atomic_swap_refresh?
          Strategies.atomic_swap!(quoter, connection, table_name, source_sql)
        else
          Strategies.truncate_insert!(quoter, connection, table_name, source_sql)
        end
      end
    end
  end
end
