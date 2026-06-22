# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Infers a view's cache-table columns from its source relation and provisions the table.
    #
    # @api private
    module CacheTableSchema
      extend T::Sig

      # An inferred cache-table column: name from the relation projection, type
      # one of :integer, :decimal, :boolean, :datetime, :string.
      class ColumnDefinition < T::Struct
        const :name, String
        const :type, Symbol
      end

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

      # The inferred MV columns (names from the projection, types from a one-row
      # probe). Shared by table creation, migration generation, and drift checks.
      sig { params(connection: Connection, relation: ::ActiveRecord::Relation).returns(T::Array[ColumnDefinition]) }
      def column_definitions(connection, relation)
        result = connection.exec_query(relation.limit(1).to_sql)
        sample = result.rows.first
        result.columns.each_with_index.map do |name, index|
          ColumnDefinition.new(name: name, type: type_for_value(sample&.at(index)))
        end
      end

      sig { params(connection: Connection, table_name: String, relation: ::ActiveRecord::Relation).void }
      def build_table!(connection, table_name, relation)
        definitions = column_definitions(connection, relation)
        connection.create_table(table_name) do |table|
          definitions.each { |definition| T.unsafe(table).public_send(definition.type, definition.name) }
        end
      end
      private_class_method :build_table!

      sig { params(value: T.untyped).returns(Symbol) }
      def type_for_value(value)
        case value
        when Integer then :integer
        when Float, BigDecimal then :decimal
        when TrueClass, FalseClass then :boolean
        when Time, Date, DateTime, ::ActiveSupport::TimeWithZone then :datetime
        else :string
        end
      end
      private_class_method :type_for_value
    end
  end
end
