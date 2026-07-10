# typed: strict
# frozen_string_literal: true

require_relative "metadata/schema"
require_relative "metadata/maintenance_payload"
require_relative "metadata/reconciliation"
require_relative "metadata/timestamps"

module ActiveRecord
  module Materialized
    # Reads and writes a view's freshness metadata row (dirty, warm, last_refreshed_at, …).
    #
    # @api private
    class Metadata
      extend T::Sig

      sig { returns(ViewClass) }
      attr_reader :view_class

      sig { params(view_class: ViewClass).void }
      def initialize(view_class)
        @view_class = view_class
        @schema_ensured = T.let(false, T::Boolean)
      end

      # Single entry point for the metadata row. Provision the schema once per
      # instance — re-ensuring on every access thrashes the schema cache and
      # makes high-write workloads quadratic.
      sig { returns(MetadataRecord) }
      def record
        ensure_schema!
        MetadataRecord.find_or_initialize_by(view_name: view_class.view_key)
      end

      sig { void }
      def ensure_schema!
        return if @schema_ensured

        Schema.ensure_table!(view_class)
        @schema_ensured = true
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
        !!record.dirty?
      end

      # Warm once fully materialized via rebuild!; cold views read through.
      sig { returns(T::Boolean) }
      def warm?
        !!record.warm?
      end

      sig { void }
      def mark_warm!
        record.update!(warm: true)
      end

      sig { params(max_staleness: T.nilable(StalenessDuration)).returns(T::Boolean) }
      def stale?(max_staleness: view_class.resolved_max_staleness)
        return true if dirty?
        return true if last_refreshed_at.nil?
        return false if max_staleness.nil?

        # A reconcile verifies contents against the source, so it resets the staleness
        # clock like a refresh — measure age from whichever happened later.
        freshest = [T.must(last_refreshed_at), record.last_reconciled_at].compact.max_by(&:to_time)
        T.must(freshest).to_time < Timestamps.threshold(max_staleness).to_time
      end

      sig { void }
      def mark_dirty!
        record.update!(dirty: true)
      end

      sig { params(payload: T::Hash[String, T.untyped]).void }
      def record_maintenance_payload!(payload)
        MaintenancePayload.record!(self, payload)
      end

      sig { returns(T.nilable(T::Hash[String, T.untyped])) }
      def maintenance_payload
        MaintenancePayload.fetch(self)
      end

      sig { void }
      def clear_maintenance_payload!
        MaintenancePayload.clear!(self)
      end

      sig { void }
      def mark_refreshing!
        record.update!(
          refreshing: true,
          last_error: nil
        )
      end

      sig { params(row_count: Integer, duration_ms: Integer).void }
      def mark_refreshed!(row_count:, duration_ms:)
        record.update!(
          last_refreshed_at: Timestamps.current,
          refreshing: false,
          dirty: false,
          row_count: row_count,
          refresh_duration_ms: duration_ms,
          last_error: nil,
          maintenance_payload: nil
        )
      end

      sig { params(error: StandardError).void }
      def mark_failed!(error)
        record.update!(
          refreshing: false,
          last_error: error.message
        )
      end
    end
  end
end
