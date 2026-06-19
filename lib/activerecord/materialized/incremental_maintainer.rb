# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class IncrementalMaintainer
      extend T::Sig

      sig { params(view_class: ViewClass).void }
      def initialize(view_class)
        @view_class = view_class
      end

      sig { params(connection: Connection, table_name: String).returns(Integer) }
      def maintain!(connection, table_name)
        delta = maintenance_store.consume_pending_delta!
        maintenance_sql = resolve_maintenance_sql(delta)
        temp_table = T.let(nil, T.nilable(String))

        temp_table = "#{table_name}_maint_#{SecureRandom.hex(4)}"
        connection.execute("CREATE TEMP TABLE #{quote_table(temp_table)} AS #{maintenance_sql}")

        connection.transaction do
          if delta.full_partition?
            connection.execute("DELETE FROM #{quote_table(table_name)}")
          else
            delete_partitions!(connection, table_name, delta.key_tuples)
          end

          connection.execute(<<~SQL.squish)
            INSERT INTO #{quote_table(table_name)}
            SELECT * FROM #{quote_table(temp_table)}
          SQL
        end

        cache_row_count(connection, table_name)
      ensure
        connection.execute("DROP TABLE IF EXISTS #{quote_table(temp_table)}") if temp_table
      end

      private

      sig { returns(ViewClass) }
      attr_reader :view_class

      sig { returns(MaintenanceStore) }
      def maintenance_store
        MaintenanceStore.new(view_class)
      end

      sig { params(delta: MaintenanceDelta).returns(String) }
      def resolve_maintenance_sql(delta)
        if view_class.incremental_source_override?
          view_class.resolved_incremental_sql
        elsif delta.full_partition?
          view_class.resolved_source_sql
        else
          view_class.view_definition.scoped_source_sql(delta.key_tuples)
        end
      end

      sig do
        params(
          connection: Connection,
          table_name: String,
          key_tuples: T::Array[T::Array[String]]
        ).void
      end
      def delete_partitions!(connection, table_name, key_tuples)
        columns = view_class.maintenance_key_columns
        if columns.size == 1
          column = quote_column(T.must(columns.first))
          values = key_tuples.map { |tuple| quote_literal(connection, tuple.fetch(0)) }.join(", ")
          connection.execute("DELETE FROM #{quote_table(table_name)} WHERE #{column} IN (#{values})")
          return
        end

        key_projection = columns.map { |column| quote_column(column) }.join(", ")
        rows = key_tuples.map do |tuple|
          "(#{tuple.map { |value| quote_literal(connection, value) }.join(', ')})"
        end.join(", ")
        connection.execute(<<~SQL.squish)
          DELETE FROM #{quote_table(table_name)}
          WHERE (#{key_projection}) IN (VALUES #{rows})
        SQL
      end

      sig { params(connection: Connection, table_name: String).returns(Integer) }
      def cache_row_count(connection, table_name)
        connection.select_value("SELECT COUNT(*) FROM #{quote_table(table_name)}").to_i
      end

      sig { params(connection: Connection, value: String).returns(String) }
      def quote_literal(connection, value)
        connection.quote(value)
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
