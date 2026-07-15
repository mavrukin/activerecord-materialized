# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Infers a view's cache-table columns from its source relation and provisions the table.
    #
    # @api private
    module CacheTableSchema
      extend T::Sig

      # DECIMAL precision for a SUM/AVG column, whose result exceeds the aggregated source
      # column's own budget — a sum grows past its integer-digit range, an average past its
      # scale. Wide enough for any realistic aggregate and within MySQL's DECIMAL(65) cap.
      AGGREGATE_PRECISION = 38

      # Extra fractional digits an average introduces beyond its source column's scale
      # (matching MySQL's own AVG widening). A materialized average is exact for a
      # terminating result; a non-terminating one (e.g. PostgreSQL AVG of 1, 2, 2) is
      # rounded at this scale — inherent to storing a division result in a fixed column.
      AVG_SCALE_HEADROOM = 4

      # Source column types that map directly to a create_table column builder. A type
      # outside this set (e.g. a PostgreSQL enum, whose declared type is the enum's own
      # name) has no `t.<type>` shorthand, so it degrades to :string rather than crashing
      # table creation.
      SAFE_TYPES = %i[integer bigint decimal float boolean string text binary datetime date time].freeze

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

      # The inferred MV columns. Names come from the query's projection (authoritative,
      # via a zero-row probe); types are inferred *structurally* from each projected node,
      # deriving from the aggregated/grouped source column so the cache mirrors the real
      # data's constraints:
      #   - a group key or plain projection takes its source column's declared type, and
      #     for a decimal its exact precision/scale;
      #   - MIN/MAX return a source value unchanged, so they mirror the source column too;
      #   - SUM/AVG derive a wide DECIMAL from the aggregated column (a sum outgrows the
      #     source's integer digits; an average adds fractional scale);
      #   - COUNT is an integer count.
      # This is deterministic and correct even when the source is empty (a sampled-row
      # probe types everything :string). Shared by table creation, migration generation,
      # and drift checks.
      sig { params(connection: Connection, relation: ::ActiveRecord::Relation).returns(T::Array[ColumnDefinition]) }
      def column_definitions(connection, relation)
        nodes = T.unsafe(relation).select_values
        connection.exec_query(relation.limit(0).to_sql).columns.each_with_index.map do |name, index|
          column_definition_for(connection, relation, nodes[index], name)
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

      # The cache column for one projected node — an Arel aggregate, a plain attribute, an
      # aliased wrapper of either, or a bare Symbol / raw name resolved against the source
      # schema. Falls back to a :string column when a node can't be classified.
      sig do
        params(connection: Connection, relation: ::ActiveRecord::Relation, node: T.untyped, name: String)
          .returns(ColumnDefinition)
      end
      def column_definition_for(connection, relation, node, name)
        node = node.left if node.is_a?(::Arel::Nodes::As)
        aggregate_column(connection, node, name) ||
          attribute_column(connection, node, name) ||
          named_column(relation, name) ||
          ColumnDefinition.new(name: name, type: :string)
      end
      private_class_method :column_definition_for

      # A column for an Arel aggregate function, or nil when the node is not one (so the
      # caller falls through to plain-attribute / named-column handling).
      sig { params(connection: Connection, node: T.untyped, name: String).returns(T.nilable(ColumnDefinition)) }
      def aggregate_column(connection, node, name)
        case node
        when ::Arel::Nodes::Count then ColumnDefinition.new(name: name, type: :integer)
        when ::Arel::Nodes::Sum then decimal_aggregate(name, source_scale(connection, node))
        when ::Arel::Nodes::Avg then decimal_aggregate(name, source_scale(connection, node) + AVG_SCALE_HEADROOM)
        when ::Arel::Nodes::Min, ::Arel::Nodes::Max then min_max_column(connection, node, name)
        end
      end
      private_class_method :aggregate_column

      # A wide DECIMAL column for a SUM/AVG result at the given scale (see AGGREGATE_PRECISION).
      sig { params(name: String, scale: Integer).returns(ColumnDefinition) }
      def decimal_aggregate(name, scale)
        ColumnDefinition.new(name: name, type: :decimal, precision: AGGREGATE_PRECISION, scale: scale)
      end
      private_class_method :decimal_aggregate

      # MIN/MAX return one of the source values unchanged, so the column mirrors the
      # aggregated attribute exactly; a wide integer-scale decimal when it can't be resolved.
      sig { params(connection: Connection, node: T.untyped, name: String).returns(ColumnDefinition) }
      def min_max_column(connection, node, name)
        attribute_column(connection, node.expressions.first, name) || decimal_aggregate(name, 0)
      end
      private_class_method :min_max_column

      # The scale of an aggregate's inner attribute (0 for an integer or unresolvable
      # column) — the fractional precision SUM preserves and AVG builds on.
      sig { params(connection: Connection, node: T.untyped).returns(Integer) }
      def source_scale(connection, node)
        inner = node.expressions.first
        return 0 unless inner.is_a?(::Arel::Attributes::Attribute)

        source_column(connection, inner)&.scale || 0
      end
      private_class_method :source_scale

      # A column mirroring the source column an Arel attribute names, read from the live
      # schema so a JOINED group key (e.g. authors.country) resolves too. nil when the node
      # is not an attribute or its table/column can't be found.
      sig { params(connection: Connection, node: T.untyped, name: String).returns(T.nilable(ColumnDefinition)) }
      def attribute_column(connection, node, name)
        return nil unless node.is_a?(::Arel::Attributes::Attribute)

        column = source_column(connection, node)
        column ? column_from_source(column, name) : nil
      end
      private_class_method :attribute_column

      # A column for a group key projected as a bare Symbol or raw name (idiomatic AR:
      # `group(:region).select(:region, ...)`), resolved by result-column name against the
      # source model's own schema. nil when the name is not one of its columns.
      sig { params(relation: ::ActiveRecord::Relation, name: String).returns(T.nilable(ColumnDefinition)) }
      def named_column(relation, name)
        column = T.unsafe(relation).klass.columns_hash[name]
        column ? column_from_source(column, name) : nil
      end
      private_class_method :named_column

      # Map a live source Column to a cache ColumnDefinition: an allowlisted create_table
      # type (see SAFE_TYPES), carrying a decimal's exact precision/scale so the cache
      # preserves the source column's value fidelity.
      sig { params(column: T.untyped, name: String).returns(ColumnDefinition) }
      def column_from_source(column, name)
        type = SAFE_TYPES.include?(column.type) ? column.type : :string
        return ColumnDefinition.new(name: name, type: type) unless type == :decimal

        ColumnDefinition.new(name: name, type: :decimal, precision: column.precision, scale: column.scale)
      end
      private_class_method :column_from_source

      # The live source Column an Arel attribute names, or nil when its table/column can't
      # be found (e.g. an aliased table, whose name is not a real relation).
      sig { params(connection: Connection, node: T.untyped).returns(T.untyped) }
      def source_column(connection, node)
        columns = connection.columns(T.unsafe(node).relation.name)
        columns.find { |candidate| candidate.name == T.unsafe(node).name.to_s }
      rescue ::ActiveRecord::StatementInvalid
        nil
      end
      private_class_method :source_column
    end
  end
end
