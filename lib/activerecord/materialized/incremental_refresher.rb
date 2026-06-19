# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class IncrementalRefresher
      extend T::Sig

      sig { params(view_class: ViewClass).void }
      def initialize(view_class)
        @view_class = view_class
      end

      sig { params(connection: Connection, table_name: String).returns(Integer) }
      def refresh!(connection, table_name)
        temp_table = T.let(nil, T.nilable(String))
        temp_table = load_delta_table(connection, table_name)
        return cache_row_count(connection, table_name) if delta_empty?(connection, temp_table)

        merge_delta_rows!(connection, table_name, temp_table, view_class.incremental_key_columns)
        cache_row_count(connection, table_name)
      ensure
        connection.execute("DROP TABLE IF EXISTS #{quote_table(temp_table)}") if temp_table
      end

      private

      sig { returns(ViewClass) }
      attr_reader :view_class

      sig { params(connection: Connection, table_name: String).returns(String) }
      def load_delta_table(connection, table_name)
        temp_table = "#{table_name}_delta_#{SecureRandom.hex(4)}"
        connection.execute(
          "CREATE TEMP TABLE #{quote_table(temp_table)} AS #{view_class.resolved_incremental_sql}"
        )
        temp_table
      end

      sig { params(connection: Connection, temp_table: String).returns(T::Boolean) }
      def delta_empty?(connection, temp_table)
        connection.select_value("SELECT COUNT(*) FROM #{quote_table(temp_table)}").to_i.zero?
      end

      sig { params(connection: Connection, table_name: String).returns(Integer) }
      def cache_row_count(connection, table_name)
        connection.select_value("SELECT COUNT(*) FROM #{quote_table(table_name)}").to_i
      end

      sig do
        params(
          connection: Connection,
          table_name: String,
          temp_table: String,
          key_columns: T::Array[String]
        ).void
      end
      def merge_delta_rows!(connection, table_name, temp_table, key_columns)
        key_projection = key_columns.map { |column| quote_column(column) }.join(", ")
        key_tuple = key_columns.size == 1 ? key_projection : "(#{key_projection})"

        connection.transaction do
          connection.execute(<<~SQL.squish)
            DELETE FROM #{quote_table(table_name)}
            WHERE #{key_tuple} IN (SELECT #{key_projection} FROM #{quote_table(temp_table)})
          SQL
          connection.execute(<<~SQL.squish)
            INSERT INTO #{quote_table(table_name)}
            SELECT * FROM #{quote_table(temp_table)}
          SQL
        end
      end

      sig { params(name: String).returns(String) }
      def quote_table(name)
        view_class.connection.quote_table_name(name)
      end

      sig { params(name: String).returns(String) }
      def quote_column(name)
        view_class.connection.quote_column_name(name)
      end
    end
  end
end
