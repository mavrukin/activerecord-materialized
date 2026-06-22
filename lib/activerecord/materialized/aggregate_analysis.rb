# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Classifies a view's projected aggregates by inspecting the source
    # relation's Arel, and decides whether the view can be maintained by
    # applying signed deltas (summary-delta IVM) rather than re-aggregating the
    # base rows of an affected partition.
    #
    # A view is delta-maintainable when it is a single-table GROUP BY with no
    # HAVING whose aggregates are all distributive (SUM / COUNT / COUNT(*)) over
    # plain columns, and it carries a trustworthy row count (COUNT(*) or COUNT of
    # a NOT NULL column) so emptied partitions can be detected. Anything else
    # (AVG, MIN, MAX, COUNT(DISTINCT), joins, HAVING, expressions) falls back to
    # scoped recompute, which is always correct.
    class AggregateAnalysis
      extend T::Sig

      class Column < T::Struct
        const :name, String
        const :function, Symbol # :sum, :count, :count_star, :avg, :min, :max, :count_distinct, :other
        const :attribute, T.nilable(String)
        const :counts_rows, T::Boolean, default: false # a trustworthy per-partition row count
      end

      sig { params(relation: ::ActiveRecord::Relation).void }
      def initialize(relation)
        @relation = relation
        @aggregate_columns = T.let(nil, T.nilable(T::Array[Column]))
      end

      sig { returns(T::Array[Column]) }
      def aggregate_columns
        @aggregate_columns ||= T.unsafe(@relation).select_values.filter_map { |value| classify(value) }
      end

      sig { returns(T::Boolean) }
      def delta_maintainable?
        single_table? && grouped? && !having? && distributive_aggregates? && aggregate_columns.any?(&:counts_rows)
      end

      sig { returns(T::Boolean) }
      def distributive_aggregates?
        aggregate_columns.any? && aggregate_columns.all? { |column| distributive?(column) }
      end

      # The column whose value reflects the partition's base-row count, used to
      # detect when a partition becomes empty.
      sig { returns(T.nilable(Column)) }
      def row_count_column
        aggregate_columns.find(&:counts_rows)
      end

      private

      sig { params(value: T.untyped).returns(T.nilable(Column)) }
      def classify(value)
        return nil unless value.is_a?(::Arel::Nodes::As)

        node = value.left
        name = alias_name(value)
        case node
        when ::Arel::Nodes::Sum then Column.new(name: name, function: :sum, attribute: attribute_name(node))
        when ::Arel::Nodes::Avg then Column.new(name: name, function: :avg, attribute: attribute_name(node))
        when ::Arel::Nodes::Min then Column.new(name: name, function: :min, attribute: attribute_name(node))
        when ::Arel::Nodes::Max then Column.new(name: name, function: :max, attribute: attribute_name(node))
        when ::Arel::Nodes::Count then count_column(name, node)
        else Column.new(name: name, function: :other)
        end
      end

      sig { params(name: String, node: T.untyped).returns(Column) }
      def count_column(name, node)
        return Column.new(name: name, function: :count_distinct, attribute: attribute_name(node)) if node.distinct
        return Column.new(name: name, function: :count_star, counts_rows: true) if star?(node)

        attribute = attribute_name(node)
        Column.new(name: name, function: :count, attribute: attribute, counts_rows: not_null_column?(attribute))
      end

      sig { params(column: Column).returns(T::Boolean) }
      def distributive?(column)
        case column.function
        when :sum, :count then !column.attribute.nil?
        when :count_star then true
        else false
        end
      end

      sig { params(node: T.untyped).returns(T.nilable(String)) }
      def attribute_name(node)
        inner = node.expressions.first
        inner.is_a?(::Arel::Attributes::Attribute) ? T.unsafe(inner).name.to_s : nil
      end

      sig { params(node: T.untyped).returns(T::Boolean) }
      def star?(node)
        inner = node.expressions.first
        !!(inner.is_a?(::Arel::Nodes::SqlLiteral) && inner.to_s == "*")
      end

      sig { params(value: ::Arel::Nodes::As).returns(String) }
      def alias_name(value)
        right = T.unsafe(value).right
        right.respond_to?(:name) ? right.name.to_s : right.to_s
      end

      sig { params(attribute: T.nilable(String)).returns(T::Boolean) }
      def not_null_column?(attribute)
        return false if attribute.nil?

        column = T.unsafe(@relation).klass.columns_hash[attribute]
        !column.nil? && !column.null
      end

      sig { returns(T::Boolean) }
      def single_table?
        T.unsafe(@relation).joins_values.empty? && T.unsafe(@relation).from_clause.value.nil?
      end

      sig { returns(T::Boolean) }
      def grouped?
        T.unsafe(@relation).group_values.any?
      end

      sig { returns(T::Boolean) }
      def having?
        !T.unsafe(@relation).having_clause.empty?
      end
    end
  end
end
