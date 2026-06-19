# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class Metadata
      module Schema
        extend T::Sig

        module_function

        sig { params(view_class: ViewClass).void }
        def ensure_table!(view_class)
          connection = view_class.connection
          create_metadata_table!(connection) unless MetadataRecord.table_exists?
          ensure_dirty_column!(connection)
          ensure_maintenance_payload_column!(connection)
          MetadataRecord.reset_column_information
        end

        sig { params(connection: Connection).void }
        def create_metadata_table!(connection)
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
end
