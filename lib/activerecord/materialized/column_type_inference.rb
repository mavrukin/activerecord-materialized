# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Infers one cache-table column (a CacheTableSchema::ColumnDefinition) from a single
    # projected node of a view's source relation, deriving from the aggregated/grouped
    # SOURCE column so the cache mirrors the real data's constraints:
    #   - a group key or plain projection takes its source column's declared type, and for
    #     a decimal its exact precision/scale;
    #   - MIN/MAX return a source value unchanged, so they mirror the source column too;
    #   - SUM/AVG derive a wide DECIMAL from the aggregated column (a sum outgrows the
    #     source's integer digits; an average adds fractional scale), or :float when the
    #     source itself is a float;
    #   - COUNT is an integer count.
    # Deterministic and correct even when the source is empty (a sampled-row probe types
    # everything :string). Used by CacheTableSchema to build tables, generate migrations,
    # and check drift.
    #
    # @api private
    module ColumnTypeInference
      extend T::Sig

      # Shorthand for the value type this module produces.
      Definition = CacheTableSchema::ColumnDefinition

      # DECIMAL precision for a SUM/AVG column, whose result exceeds the aggregated source
      # column's own budget — a sum grows past its integer-digit range, an average past its
      # scale. Wide enough for any realistic aggregate and within MySQL's DECIMAL(65) cap.
      AGGREGATE_PRECISION = 38

      # Extra fractional digits an average introduces beyond its source column's scale
      # (matching MySQL's own AVG widening). A materialized average is exact for a
      # terminating result; a non-terminating one (e.g. PostgreSQL AVG of 1, 2, 2) is
      # rounded at this scale — inherent to storing a division result in a fixed column.
      AVG_SCALE_HEADROOM = 4

      # Fractional scale for a SUM/AVG over an unscaled numeric source (one whose own
      # scale the schema does not record), so its fractional part is not truncated to zero.
      DEFAULT_DECIMAL_SCALE = 6

      # Largest DECIMAL scale every target engine accepts (MySQL caps at 30); a derived
      # scale is clamped to it so table creation never fails on an out-of-range scale.
      MAX_DECIMAL_SCALE = 30

      # Source column types that map directly to a create_table column builder. A type
      # outside this set (e.g. a PostgreSQL enum, whose declared type is the enum's own
      # name) has no `t.<type>` shorthand, so it degrades to :string rather than crashing
      # table creation.
      SAFE_TYPES = %i[integer bigint decimal float boolean string text binary datetime date time].freeze

      module_function

      # The cache column for one projected node — an Arel aggregate, a plain attribute, an
      # aliased wrapper of either, or a bare Symbol resolved against the source schema.
      # Falls back to a :string column when a node can't be classified.
      sig do
        params(connection: Connection, relation: ::ActiveRecord::Relation, node: T.untyped, name: String)
          .returns(Definition)
      end
      def definition_for(connection, relation, node, name)
        node = node.left if node.is_a?(::Arel::Nodes::As)
        aggregate_column(connection, node, name) ||
          attribute_column(connection, node, name) ||
          named_column(relation, node, name) ||
          Definition.new(name: name, type: :string)
      end

      # A column for an Arel aggregate function, or nil when the node is not one (so the
      # caller falls through to plain-attribute / named-column handling).
      sig { params(connection: Connection, node: T.untyped, name: String).returns(T.nilable(Definition)) }
      def aggregate_column(connection, node, name)
        case node
        when ::Arel::Nodes::Count then Definition.new(name: name, type: :integer)
        when ::Arel::Nodes::Sum then sum_avg_column(connection, node, name, 0)
        when ::Arel::Nodes::Avg then sum_avg_column(connection, node, name, AVG_SCALE_HEADROOM)
        when ::Arel::Nodes::Min, ::Arel::Nodes::Max then min_max_column(connection, node, name)
        end
      end

      # SUM/AVG over a float source stays :float — a fixed DECIMAL scale would truncate it.
      # Otherwise a wide DECIMAL keeping the source's fractional scale plus AVG's headroom
      # (an integer or unresolved source contributes scale 0, so a sum stays exact).
      sig { params(connection: Connection, node: T.untyped, name: String, extra_scale: Integer).returns(Definition) }
      def sum_avg_column(connection, node, name, extra_scale)
        column = aggregate_source_column(connection, node)
        return Definition.new(name: name, type: :float) if column&.type == :float

        decimal_aggregate(name, source_scale(column) + extra_scale)
      end

      # A wide DECIMAL for a SUM/AVG result, with the scale clamped to what every engine
      # accepts (MAX_DECIMAL_SCALE, always <= the precision) so table creation can't fail
      # on an out-of-range scale.
      sig { params(name: String, scale: Integer).returns(Definition) }
      def decimal_aggregate(name, scale)
        Definition.new(
          name: name, type: :decimal, precision: AGGREGATE_PRECISION, scale: scale.clamp(0, MAX_DECIMAL_SCALE)
        )
      end

      # MIN/MAX return one of the source values unchanged, so the column mirrors the
      # aggregated attribute exactly; a wide integer-scale decimal when it can't be resolved.
      sig { params(connection: Connection, node: T.untyped, name: String).returns(Definition) }
      def min_max_column(connection, node, name)
        attribute_column(connection, node.expressions.first, name) || decimal_aggregate(name, 0)
      end

      # The live source Column an aggregate is computed over (e.g. amount for SUM(amount)),
      # or nil for COUNT(*) or an aggregate not over a plain attribute.
      sig { params(connection: Connection, node: T.untyped).returns(T.untyped) }
      def aggregate_source_column(connection, node)
        inner = node.expressions.first
        inner.is_a?(::Arel::Attributes::Attribute) ? source_column(connection, inner) : nil
      end

      # The fractional scale to carry from an aggregate's source column: an integer or
      # unresolved source contributes 0 (a sum stays whole); a decimal contributes its own
      # scale, or DEFAULT_DECIMAL_SCALE for an unscaled numeric whose scale is unknown.
      sig { params(column: T.untyped).returns(Integer) }
      def source_scale(column)
        return 0 unless column&.type == :decimal

        column.scale || DEFAULT_DECIMAL_SCALE
      end

      # A column mirroring the source column an Arel attribute names, read from the live
      # schema so a JOINED group key (e.g. authors.country) resolves too. nil when the node
      # is not an attribute or its table/column can't be found.
      sig { params(connection: Connection, node: T.untyped, name: String).returns(T.nilable(Definition)) }
      def attribute_column(connection, node, name)
        return nil unless node.is_a?(::Arel::Attributes::Attribute)

        column = source_column(connection, node)
        column ? column_from_source(column, name) : nil
      end

      # A column for a group key projected as a bare Symbol (idiomatic AR:
      # `group(:region).select(:region, ...)`), resolved against the source model's own
      # schema. Only a Symbol is unambiguously a base-table column; a raw-SQL/String
      # projection may name a JOINED column that merely collides with a base column, so it
      # falls through to :string rather than risk typing it from the wrong table.
      sig { params(relation: ::ActiveRecord::Relation, node: T.untyped, name: String).returns(T.nilable(Definition)) }
      def named_column(relation, node, name)
        return nil unless node.is_a?(::Symbol)

        column = T.unsafe(relation).klass.columns_hash[name]
        column ? column_from_source(column, name) : nil
      end

      # Map a live source Column to a cache Definition: an allowlisted create_table type
      # (see SAFE_TYPES), carrying a decimal's exact precision/scale so the cache preserves
      # the source column's value fidelity.
      sig { params(column: T.untyped, name: String).returns(Definition) }
      def column_from_source(column, name)
        type = SAFE_TYPES.include?(column.type) ? column.type : :string
        return Definition.new(name: name, type: type) unless type == :decimal

        Definition.new(name: name, type: :decimal, precision: column.precision, scale: column.scale)
      end

      # The live source Column an Arel attribute names, or nil when its table/column can't
      # be found (e.g. an aliased table, whose name is not a real relation).
      sig { params(connection: Connection, node: T.untyped).returns(T.untyped) }
      def source_column(connection, node)
        columns = connection.columns(T.unsafe(node).relation.name)
        columns.find { |candidate| candidate.name == T.unsafe(node).name.to_s }
      rescue ::ActiveRecord::StatementInvalid
        nil
      end

      private_class_method :aggregate_column, :sum_avg_column, :decimal_aggregate, :min_max_column,
                           :aggregate_source_column, :source_scale, :attribute_column, :named_column,
                           :column_from_source, :source_column
    end
  end
end
