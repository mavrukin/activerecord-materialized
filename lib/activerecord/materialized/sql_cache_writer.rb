# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Fallback materializer for string SQL sources. Relation-based views should use
    # RelationCacheWriter so cache maintenance stays on ActiveRecord APIs.
    # String-SQL fallback path; kept together so relation-based code stays raw-SQL-free.
    # rubocop:disable Metrics/ClassLength
    class SqlCacheWriter
      extend T::Sig

      sig { params(view_class: ViewClass).void }
      def initialize(view_class)
        @view_class = view_class
      end

      sig { params(source_sql: String).returns(Integer) }
      def atomic_swap!(source_sql)
        connection = view_class.connection
        table_name = view_class.table_name
        temp_table = "#{table_name}_refresh_#{SecureRandom.hex(4)}"
        old_table = "#{table_name}_old_#{SecureRandom.hex(4)}"

        connection.execute("CREATE TABLE #{quote_table(temp_table)} AS #{source_sql}")
        row_count = connection.select_value("SELECT COUNT(*) FROM #{quote_table(temp_table)}").to_i

        swap_sql_tables!(connection, table_name, temp_table, old_table)

        view_class.reset_column_information
        row_count
      end

      sig { params(source_sql: String).returns(Integer) }
      def replace_all!(source_sql)
        ensure_cache_table!(source_sql)
        connection = view_class.connection
        table_name = view_class.table_name

        connection.transaction do
          view_class.delete_all
          connection.execute("INSERT INTO #{quote_table(table_name)} #{source_sql}")
        end

        view_class.count
      end

      sig do
        params(
          maintenance_sql: String,
          key_tuples: T::Array[T::Array[String]],
          full_partition: T::Boolean
        ).returns(Integer)
      end
      def replace_partitions!(maintenance_sql, key_tuples:, full_partition:)
        connection = view_class.connection
        table_name = view_class.table_name
        temp_table = "#{table_name}_maint_#{SecureRandom.hex(4)}"

        connection.execute("CREATE TEMP TABLE #{quote_table(temp_table)} AS #{maintenance_sql}")
        merge_temp_rows!(connection, table_name, temp_table, key_tuples:, full_partition:)
        view_class.count
      ensure
        connection.drop_table(temp_table, if_exists: true) if temp_table
      end

      sig do
        params(
          connection: Connection,
          table_name: String,
          temp_table: String,
          key_tuples: T::Array[T::Array[String]],
          full_partition: T::Boolean
        ).void
      end
      def merge_temp_rows!(connection, table_name, temp_table, key_tuples:, full_partition:)
        connection.transaction do
          if full_partition
            view_class.delete_all
          else
            delete_partitions!(key_tuples)
          end

          connection.execute(<<~SQL.squish)
            INSERT INTO #{quote_table(table_name)}
            SELECT * FROM #{quote_table(temp_table)}
          SQL
        end
      end

      sig { params(connection: Connection, table_name: String, temp_table: String, old_table: String).void }
      def swap_sql_tables!(connection, table_name, temp_table, old_table)
        connection.transaction do
          connection.rename_table(table_name, old_table) if view_class.table_exists?
          connection.rename_table(temp_table, table_name)
          connection.drop_table(old_table, if_exists: true)
        end
      end

      private

      sig { returns(ViewClass) }
      attr_reader :view_class

      sig { returns(Connection) }
      def connection
        view_class.connection
      end

      sig { params(source_sql: String).void }
      def ensure_cache_table!(source_sql)
        return if view_class.table_exists?

        connection.execute("CREATE TABLE #{quote_table(view_class.table_name)} AS #{source_sql} WHERE 1=0")
        view_class.reset_column_information
      end

      sig { params(key_tuples: T::Array[T::Array[String]]).void }
      def delete_partitions!(key_tuples)
        columns = view_class.maintenance_key_columns
        if columns.size == 1
          column = columns.fetch(0)
          view_class.where(column => key_tuples.map(&:first)).delete_all
          return
        end

        view_class.view_definition.partition_scope_on(view_class, key_tuples).delete_all
      end

      sig { params(name: String).returns(String) }
      def quote_table(name)
        connection.quote_table_name(name)
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
