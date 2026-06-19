# typed: strict
# frozen_string_literal: true

require_relative "metadata/schema"

module ActiveRecord
  module Materialized
    class Metadata
      extend T::Sig

      sig { returns(ViewClass) }
      attr_reader :view_class

      sig { params(view_class: ViewClass).void }
      def initialize(view_class)
        @view_class = view_class
      end

      sig { returns(MetadataRecord) }
      def record
        Schema.ensure_table!(view_class)
        MetadataRecord.find_or_initialize_by(view_name: view_class.view_key)
      end

      sig { returns(T.nilable(Timestamp)) }
      def last_refreshed_at
        record.last_refreshed_at
      end

      sig { returns(T::Boolean) }
      def refreshing?
        !!record.refreshing?
      end

      sig { returns(T.nilable(Integer)) }
      def row_count
        record.row_count
      end

      sig { returns(T.nilable(Integer)) }
      def refresh_duration_ms
        record.refresh_duration_ms
      end

      sig { returns(T::Boolean) }
      def dirty?
        Schema.ensure_table!(view_class)
        !!record.dirty?
      end

      sig { params(max_staleness: T.nilable(StalenessDuration)).returns(T::Boolean) }
      def stale?(max_staleness: view_class.resolved_max_staleness)
        return true if dirty?
        return true if last_refreshed_at.nil?
        return false if max_staleness.nil?

        refreshed_at = T.must(last_refreshed_at)
        refreshed_at.to_time < duration_threshold(max_staleness).to_time
      end

      sig { void }
      def mark_dirty!
        Schema.ensure_table!(view_class)
        record.update!(dirty: true)
      end

      sig { void }
      def mark_refreshing!
        Schema.ensure_table!(view_class)
        record.update!(
          refreshing: true,
          last_error: nil
        )
      end

      sig { params(row_count: Integer, duration_ms: Integer).void }
      def mark_refreshed!(row_count:, duration_ms:)
        Schema.ensure_table!(view_class)
        record.update!(
          last_refreshed_at: ::Time.zone.now,
          refreshing: false,
          dirty: false,
          row_count: row_count,
          refresh_duration_ms: duration_ms,
          last_error: nil
        )
      end

      sig { params(error: StandardError).void }
      def mark_failed!(error)
        Schema.ensure_table!(view_class)
        record.update!(
          refreshing: false,
          last_error: error.message
        )
      end

      private

      sig { params(staleness: StalenessDuration).returns(Timestamp) }
      def duration_threshold(staleness)
        if staleness.is_a?(Integer)
          ::ActiveSupport::Duration.seconds(staleness).ago
        else
          staleness.ago
        end
      end
    end
  end
end
