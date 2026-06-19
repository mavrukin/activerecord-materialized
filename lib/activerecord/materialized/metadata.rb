# typed: strict
# frozen_string_literal: true

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
        ensure_table!
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
        ensure_table!
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
        ensure_table!
        record.update!(dirty: true)
      end

      sig { params(payload: T::Hash[String, T.untyped]).void }
      def record_maintenance_payload!(payload)
        ensure_table!
        record.update!(maintenance_payload: payload.to_json)
      end

      sig { returns(T.nilable(T::Hash[String, T.untyped])) }
      def maintenance_payload
        ensure_table!
        raw = T.unsafe(record).maintenance_payload
        return nil if raw.blank?

        JSON.parse(raw)
      end

      sig { void }
      def clear_maintenance_payload!
        ensure_table!
        record.update!(maintenance_payload: nil)
      end

      sig { void }
      def mark_refreshing!
        ensure_table!
        record.update!(
          refreshing: true,
          last_error: nil
        )
      end

      sig { params(row_count: Integer, duration_ms: Integer).void }
      def mark_refreshed!(row_count:, duration_ms:)
        ensure_table!
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
        ensure_table!
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

      sig { void }
      def ensure_table!
        connection = view_class.connection

        unless MetadataRecord.table_exists?
          connection.create_table(::ActiveRecord::Materialized.metadata_table_name, force: :cascade) do |t|
            t.string :view_name, null: false
            t.datetime :last_refreshed_at
            t.boolean :refreshing, null: false, default: false
            t.boolean :dirty, null: false, default: true
            t.integer :row_count
            t.integer :refresh_duration_ms
            t.text :last_error
            t.text :maintenance_payload
            t.timestamps
          end
          connection.add_index(::ActiveRecord::Materialized.metadata_table_name, :view_name, unique: true)
        end

        ensure_dirty_column!(connection)
        ensure_maintenance_payload_column!(connection)
        MetadataRecord.reset_column_information
      end

      sig { params(connection: Connection).void }
      def ensure_dirty_column!(connection)
        return unless MetadataRecord.table_exists?
        return if MetadataRecord.column_names.include?("dirty")

        connection.add_column(
          ::ActiveRecord::Materialized.metadata_table_name,
          :dirty,
          :boolean,
          default: true,
          null: false
        )
      end

      sig { params(connection: Connection).void }
      def ensure_maintenance_payload_column!(connection)
        return unless MetadataRecord.table_exists?
        return if MetadataRecord.column_names.include?("maintenance_payload")

        connection.add_column(
          ::ActiveRecord::Materialized.metadata_table_name,
          :maintenance_payload,
          :text
        )
      end
    end
  end
end
