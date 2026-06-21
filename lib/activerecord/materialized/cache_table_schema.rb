# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    module CacheTableSchema
      extend T::Sig

      module_function

      sig { params(view_class: T.class_of(::ActiveRecord::Base), relation: ::ActiveRecord::Relation).void }
      def ensure_table!(view_class, relation)
        return if view_class.table_exists?

        build_table!(view_class.connection, view_class.table_name, relation)
        view_class.reset_column_information
      end

      sig { params(view_class: T.class_of(::ActiveRecord::Base), table_name: String, relation: ::ActiveRecord::Relation).void }
      def create_table!(view_class, table_name, relation)
        build_table!(view_class.connection, table_name, relation)
      end

      sig { params(connection: Connection, table_name: String, relation: ::ActiveRecord::Relation).void }
      def build_table!(connection, table_name, relation)
        # Probe one row for column names and value-based type inference. Never
        # buffer the whole result set just to learn the schema.
        result = connection.exec_query(relation.limit(1).to_sql)
        columns = result.columns
        sample = result.rows.first

        connection.create_table(table_name) do |table|
          columns.each_with_index do |column_name, index|
            add_column_for_value(table, column_name, sample&.at(index))
          end
        end
      end
      private_class_method :build_table!

      sig { params(table: T.untyped, column_name: String, value: T.untyped).void }
      def add_column_for_value(table, column_name, value)
        case value
        when Integer
          table.integer(column_name)
        when Float, BigDecimal
          table.decimal(column_name)
        when TrueClass, FalseClass
          table.boolean(column_name)
        when Time, Date, DateTime, ::ActiveSupport::TimeWithZone
          table.datetime(column_name)
        else
          table.string(column_name)
        end
      end
      private_class_method :add_column_for_value
    end
  end
end
