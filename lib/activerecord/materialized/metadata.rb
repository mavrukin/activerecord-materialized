# frozen_string_literal: true

module ActiveRecord
  module Materialized
  class Metadata
    attr_reader :view_class

    def initialize(view_class)
      @view_class = view_class
    end

    def record
      ensure_table!
      MetadataRecord.find_or_initialize_by(view_name: view_class.view_key)
    end

    def last_refreshed_at
      record.last_refreshed_at
    end

    def refreshing?
      record.refreshing?
    end

    def row_count
      record.row_count
    end

    def refresh_duration_ms
      record.refresh_duration_ms
    end

    def dirty?
      ensure_table!
      record.dirty?
    end

    def stale?(max_staleness: view_class.resolved_max_staleness)
      return true if dirty?
      return true if last_refreshed_at.nil?
      return false if max_staleness.nil?

      last_refreshed_at < max_staleness.ago
    end

    def mark_dirty!
      ensure_table!
      record.update!(dirty: true)
    end

    def mark_refreshing!
      ensure_table!
      record.update!(
        refreshing: true,
        last_error: nil
      )
    end

    def mark_refreshed!(row_count:, duration_ms:)
      ensure_table!
      record.update!(
        last_refreshed_at: Time.current,
        refreshing: false,
        dirty: false,
        row_count: row_count,
        refresh_duration_ms: duration_ms,
        last_error: nil
      )
    end

    def mark_failed!(error)
      ensure_table!
      record.update!(
        refreshing: false,
        last_error: error.message
      )
    end

    private

    def ensure_table!
      connection = view_class.connection

      unless MetadataRecord.table_exists?
        connection.create_table ActiveRecord::Materialized.metadata_table_name, force: :cascade do |t|
          t.string :view_name, null: false
          t.datetime :last_refreshed_at
          t.boolean :refreshing, null: false, default: false
          t.boolean :dirty, null: false, default: true
          t.integer :row_count
          t.integer :refresh_duration_ms
          t.text :last_error
          t.timestamps
        end
        connection.add_index ActiveRecord::Materialized.metadata_table_name, :view_name, unique: true
      end

      ensure_dirty_column!(connection)
      MetadataRecord.reset_column_information
    end

    def ensure_dirty_column!(connection)
      return unless MetadataRecord.table_exists?
      return if MetadataRecord.column_names.include?("dirty")

      connection.add_column ActiveRecord::Materialized.metadata_table_name, :dirty, :boolean, default: true, null: false
    end

    class MetadataRecord < ::ActiveRecord::Base
      self.table_name = ActiveRecord::Materialized.metadata_table_name

      def self.table_name=(name)
        @table_name_override = name
      end

      def self.table_name
        @table_name_override || ActiveRecord::Materialized.metadata_table_name
      end
    end
  end
  end
end
