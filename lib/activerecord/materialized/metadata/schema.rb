# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class Metadata
      # Lazily provisions and migrates the materialized-view metadata table.
      #
      # @api private
      module Schema
        extend T::Sig

        module_function

        sig { params(view_class: ViewClass).void }
        def ensure_table!(view_class)
          connection = view_class.connection
          create_metadata_table!(connection) unless MetadataRecord.table_exists?
          ensure_columns!(connection)
          MetadataRecord.reset_column_information
        end

        sig { params(connection: Connection).void }
        def create_metadata_table!(connection)
          connection.create_table(::ActiveRecord::Materialized.metadata_table_name, force: :cascade) do |t|
            t.string :view_name, null: false
            t.datetime :last_refreshed_at
            t.boolean :refreshing, null: false, default: false
            t.boolean :dirty, null: false, default: true
            t.boolean :warm, null: false, default: false
            t.integer :row_count
            t.integer :refresh_duration_ms
            t.text :last_error
            t.text :maintenance_payload
            t.datetime :last_reconciled_at
            t.integer :reconciled_partition_count
            t.timestamps
          end
          connection.add_index(::ActiveRecord::Materialized.metadata_table_name, :view_name, unique: true)
        end

        # Lazily add columns introduced after a table was first provisioned, so an app
        # migrated from an earlier version picks them up without a new migration.
        sig { params(connection: Connection).void }
        def ensure_columns!(connection)
          return unless MetadataRecord.table_exists?

          ensure_column!(connection, :dirty, :boolean, default: true, null: false)
          ensure_column!(connection, :warm, :boolean, default: false, null: false)
          ensure_column!(connection, :maintenance_payload, :text)
          ensure_column!(connection, :last_reconciled_at, :datetime)
          ensure_column!(connection, :reconciled_partition_count, :integer)
        end

        sig { params(connection: Connection, name: Symbol, type: Symbol, default: T.untyped, null: T::Boolean).void }
        def ensure_column!(connection, name, type, default: nil, null: true)
          return if MetadataRecord.column_names.include?(name.to_s)

          connection.add_column(
            ::ActiveRecord::Materialized.metadata_table_name, name, type, default: default, null: null
          )
        end
      end
    end
  end
end
