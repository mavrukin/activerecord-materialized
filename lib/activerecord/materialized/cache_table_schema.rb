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

        connection = view_class.connection
        result = connection.exec_query(relation.to_sql)
        columns = result.columns
        sample = result.rows.first

        connection.create_table(view_class.table_name) do |table|
          columns.each_with_index do |column_name, index|
            add_column_for_value(table, column_name, sample&.at(index))
          end
        end

        view_class.reset_column_information
      end

      sig { params(view_class: T.class_of(::ActiveRecord::Base), table_name: String, relation: ::ActiveRecord::Relation).void }
      def create_table!(view_class, table_name, relation)
        connection = view_class.connection
        result = connection.exec_query(relation.to_sql)
        columns = result.columns
        sample = result.rows.first

        connection.create_table(table_name) do |table|
          columns.each_with_index do |column_name, index|
            add_column_for_value(table, column_name, sample&.at(index))
          end
        end
      end

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
