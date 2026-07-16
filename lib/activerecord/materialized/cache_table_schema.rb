# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Provisions a view's cache table from its source relation. The per-column type
    # inference lives in ColumnTypeInference; this module maps the inferred definitions
    # onto create_table (and, via MigrationBuilder, a generated migration).
    #
    # @api private
    module CacheTableSchema
      extend T::Sig

      # An inferred cache-table column: name from the relation projection, a create_table
      # column type, and — for a :decimal — the precision/scale that preserve value
      # fidelity (a bare `decimal` is DECIMAL(10,0) on MySQL, which truncates).
      class ColumnDefinition < T::Struct
        extend T::Sig

        const :name, String
        const :type, Symbol
        const :precision, T.nilable(Integer), default: nil
        const :scale, T.nilable(Integer), default: nil

        # create_table options for this column (precision/scale for a decimal; none otherwise).
        sig { returns(T::Hash[Symbol, Integer]) }
        def options
          { precision: precision, scale: scale }.compact
        end

        # The trailing arguments for a `t.<type> :<name>` migration line ("" when none).
        sig { returns(String) }
        def migration_arguments
          options.map { |key, value| ", #{key}: #{value}" }.join
        end
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

      # The inferred MV columns. Names come from the query's projection (authoritative, via
      # a zero-row probe); each column's type is inferred structurally from its projected
      # node by ColumnTypeInference. Shared by table creation, migration generation, and
      # drift checks.
      sig { params(connection: Connection, relation: ::ActiveRecord::Relation).returns(T::Array[ColumnDefinition]) }
      def column_definitions(connection, relation)
        nodes = T.unsafe(relation).select_values
        connection.exec_query(relation.limit(0).to_sql).columns.each_with_index.map do |name, index|
          ColumnTypeInference.definition_for(connection, relation, nodes[index], name)
        end
      end

      sig { params(connection: Connection, table_name: String, relation: ::ActiveRecord::Relation).void }
      def build_table!(connection, table_name, relation)
        definitions = column_definitions(connection, relation)
        connection.create_table(table_name) do |table|
          definitions.each do |definition|
            T.unsafe(table).public_send(definition.type, definition.name, **definition.options)
          end
        end
      end
      private_class_method :build_table!
    end
  end
end
