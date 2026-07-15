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

      # The inferred MV columns. Names come from the query's projection (authoritative,
      # via a zero-row probe); types are inferred *structurally* from each projected
      # node — a group key takes its source column's declared type, an aggregate takes
      # a type from its function (COUNT → integer, AVG → decimal, SUM/MIN/MAX from the
      # aggregated column). This is deterministic and engine-independent, so a view's
      # cache schema matches across adapters and is correct even when the source is
      # empty (a sampled-row probe types everything :string). Shared by table creation,
      # migration generation, and drift checks.
      sig { params(connection: Connection, relation: ::ActiveRecord::Relation).returns(T::Array[ColumnDefinition]) }
      def column_definitions(connection, relation)
        nodes = T.unsafe(relation).select_values
        connection.exec_query(relation.limit(0).to_sql).columns.each_with_index.map do |name, index|
          ColumnDefinition.new(name: name, type: type_for_node(connection, nodes[index]))
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

      # The cache column type for one projected node — an Arel aggregate, a plain
      # attribute, or an aliased wrapper of either. Falls back to :string when a node
      # can't be classified.
      sig { params(connection: Connection, node: T.untyped).returns(Symbol) }
      def type_for_node(connection, node)
        node = node.left if node.is_a?(::Arel::Nodes::As)
        aggregate_type(connection, node) || attribute_type(connection, node) || :string
      end
      private_class_method :type_for_node

      # A type for an Arel aggregate function node, or nil when the node is not one
      # (so the caller falls through to plain-attribute / :string handling).
      sig { params(connection: Connection, node: T.untyped).returns(T.nilable(Symbol)) }
      def aggregate_type(connection, node)
        case node
        when ::Arel::Nodes::Count then :integer
        when ::Arel::Nodes::Avg then :decimal
        when ::Arel::Nodes::Sum then sum_type(connection, node)
        when ::Arel::Nodes::Min, ::Arel::Nodes::Max then aggregate_attribute_type(connection, node) || :decimal
        end
      end
      private_class_method :aggregate_type

      # SUM over an integer column stays integer; over decimal/float it is decimal.
      sig { params(connection: Connection, node: T.untyped).returns(Symbol) }
      def sum_type(connection, node)
        aggregate_attribute_type(connection, node) == :integer ? :integer : :decimal
      end
      private_class_method :sum_type

      # The source column type of an aggregate's inner attribute (e.g. amount for
      # SUM(amount)), or nil when the aggregate is not over a plain column (e.g. COUNT(*)).
      sig { params(connection: Connection, node: T.untyped).returns(T.nilable(Symbol)) }
      def aggregate_attribute_type(connection, node)
        inner = node.expressions.first
        inner.is_a?(::Arel::Attributes::Attribute) ? attribute_type(connection, inner) : nil
      end
      private_class_method :aggregate_attribute_type

      # The declared type of the table column an Arel attribute names, read from the
      # live schema so a JOINED group key (e.g. authors.country) resolves too. nil when
      # the table/column can't be found.
      sig { params(connection: Connection, node: T.untyped).returns(T.nilable(Symbol)) }
      def attribute_type(connection, node)
        return nil unless node.is_a?(::Arel::Attributes::Attribute)

        columns = connection.columns(T.unsafe(node).relation.name)
        column = columns.find { |candidate| candidate.name == T.unsafe(node).name.to_s }
        column&.type
      rescue ::ActiveRecord::StatementInvalid
        nil
      end
      private_class_method :attribute_type
    end
  end
end
