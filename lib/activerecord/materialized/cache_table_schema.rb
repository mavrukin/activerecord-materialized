# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Provisions a view's cache table from its source relation. The per-column type
    # inference lives in ColumnTypeInference; this module maps the inferred definitions
    # onto create_table (and, via MigrationBuilder, a generated migration).
    #
    # @api private
    module CacheTableSchema
      # An inferred cache-table column: name from the relation projection, a create_table
      # column type, and — for a :decimal — the precision/scale that preserve value
      # fidelity (a bare `decimal` is DECIMAL(10,0) on MySQL, which truncates).
      ColumnDefinition = Data.define(:name, :type, :precision, :scale) do
        def initialize(name:, type:, precision: nil, scale: nil) = super

        # create_table options for this column (precision/scale for a decimal; none otherwise).
        def options
          { precision: precision, scale: scale }.compact
        end

        # The trailing arguments for a `t.<type> :<name>` migration line ("" when none).
        def migration_arguments
          options.map { |key, value| ", #{key}: #{value}" }.join
        end
      end

      # The partition-key index a cache table is built with: the GROUP BY / maintenance-key columns
      # (unqualified to their cache-column names), unique when the key is the whole partition identity
      # (a plain GROUP BY, one row per group). Incremental maintenance filters/deletes/re-selects by
      # exactly these columns, so without this index every partition operation is a full cache scan.
      #
      # @api private
      IndexDefinition = Data.define(:columns, :unique)

      module_function

      def ensure_table!(view_class, relation)
        return if view_class.table_exists?

        build_table!(view_class.connection, view_class.table_name, relation, index: index_definition(view_class))
        view_class.reset_column_information
      end

      def create_table!(view_class, table_name, relation)
        build_table!(view_class.connection, table_name, relation, index: index_definition(view_class))
      end

      # The partition-key index for a view, or nil for a non-grouped view (no maintenance key to index).
      # A key derived purely from the GROUP BY is the partition identity, so the index is UNIQUE — which
      # also structurally prevents duplicate partition rows under concurrent maintenance (see #95). An
      # explicit +incremental_keys+ override may be coarser than the grouping, so that index is non-unique.
      #
      # @return [IndexDefinition, nil]
      def index_definition(view_class)
        keys = view_class.maintenance_key_columns
        return nil if keys.empty?

        columns = keys.map { |key| key.rpartition(".").last }
        IndexDefinition.new(columns: columns, unique: view_class.incremental_key_columns.empty?)
      end

      # The inferred MV columns. Names come from the query's projection (authoritative, via
      # a zero-row probe); each column's type is inferred structurally from its projected
      # node by ColumnTypeInference. Shared by table creation, migration generation, and
      # drift checks.
      def column_definitions(connection, relation)
        nodes = relation.select_values
        connection.exec_query(relation.limit(0).to_sql).columns.each_with_index.map do |name, index|
          ColumnTypeInference.definition_for(connection, relation, nodes[index], name)
        end
      end

      def build_table!(connection, table_name, relation, index: nil)
        definitions = column_definitions(connection, relation)
        connection.create_table(table_name) do |table|
          definitions.each do |definition|
            table.public_send(definition.type, definition.name, **definition.options)
          end
          table.index(index.columns, unique: index.unique) if index
        end
      end
      private_class_method :build_table!
    end
  end
end
