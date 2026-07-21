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
      attr_reader :view_class

      def initialize(view_class)
        @view_class = view_class
        @schema_ensured = false
      end

      # Single entry point for the metadata row. Provision the schema once per
      # instance — re-ensuring on every access thrashes the schema cache and
      # makes high-write workloads quadratic.
      def record
        ensure_schema!
        MetadataRecord.find_or_initialize_by(view_name: view_class.view_key)
      end

      def ensure_schema!
        return if @schema_ensured

        Schema.ensure_table!(view_class)
        @schema_ensured = true
      end

      def last_refreshed_at
        record.last_refreshed_at
      end

      def refreshing?
        !!record.refreshing?
      end

      def row_count
        record.row_count
      end

      def refresh_duration_ms
        record.refresh_duration_ms
      end

      def dirty?
        !!record.dirty?
      end

      # Warm once fully materialized via rebuild!; cold views read through.
      def warm?
        !!record.warm?
      end

      def mark_warm!
        record.update!(warm: true)
      end

      # The current fresh-set epoch for this view (see PartitionState). A populate captures it before
      # its source read; all_fresh? honours only marks stamped with the current value. (#120)
      def fresh_set_generation
        record.fresh_set_generation
      end

      # Advance the fresh-set epoch atomically so every mark stamped with an earlier value is treated
      # as stale — used by PartitionState#reset! to invalidate a cold view's whole fresh set on a widen.
      # Ensures the row exists first (create_or_find_by absorbs a concurrent first insert), then a single
      # atomic SQL increment (never a read-then-write), so two concurrent resets can't lost-update the
      # epoch — a populate that captured any earlier value still fails all_fresh?. Portable across adapters.
      def bump_fresh_set_generation!
        ensure_schema!
        MetadataRecord.create_or_find_by(view_name: view_class.view_key)
        connection = view_class.connection
        table = connection.quote_table_name(::ActiveRecord::Materialized.metadata_table_name)
        connection.execute(
          "UPDATE #{table} SET fresh_set_generation = fresh_set_generation + 1 " \
          "WHERE view_name = #{connection.quote(view_class.view_key)}"
        )
      end

      def stale?(max_staleness: view_class.resolved_max_staleness)
        return true if dirty?
        return true if last_refreshed_at.nil?
        return false if max_staleness.nil?

        # A reconcile verifies contents against the source, so it resets the staleness clock like a
        # refresh — measure age from whichever happened later. The replica-lag budget tightens the
        # window: a replica read trails the primary by the lag, so the view goes stale that much
        # sooner to keep replica reads within max_staleness.
        freshest = [last_refreshed_at, record.last_reconciled_at].compact.max_by(&:to_time)
        freshest.to_time < Timestamps.threshold(effective_staleness(max_staleness)).to_time
      end

      def mark_dirty!
        record.update!(dirty: true)
      end

      def record_maintenance_payload!(payload)
        MaintenancePayload.record!(self, payload)
      end

      def maintenance_payload
        MaintenancePayload.fetch(self)
      end

      def clear_maintenance_payload!
        MaintenancePayload.clear!(self)
      end

      def mark_refreshing!
        record.update!(
          refreshing: true,
          last_error: nil
        )
      end

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

      def mark_failed!(error)
        record.update!(
          refreshing: false,
          last_error: error.message
        )
      end

      private

      # max_staleness minus the configured replica-lag budget (clamped at 0), so replica reads stay
      # within the window. Zero lag (the default) leaves max_staleness unchanged.
      def effective_staleness(max_staleness)
        lag = ActiveRecord::Materialized.configuration.replica_lag
        return max_staleness if lag.nil? || lag.zero?

        [max_staleness - lag, 0].max
      end
    end
  end
end
