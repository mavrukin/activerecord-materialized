# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Decides whether a view can be maintained by applying signed deltas
    # (summary-delta IVM) instead of re-aggregating a partition's base rows. True
    # only for a single-table GROUP BY without HAVING whose aggregates are all
    # distributive (SUM/COUNT/COUNT(*)) and which carries a trustworthy row count
    # so emptied partitions can be detected; everything else falls back to scoped
    # recompute, which is always correct.
    class AggregateAnalysis
      # One classified aggregate column from a view's projection.
      #
      # @api private
      Column = Data.define(:name, :function, :attribute, :counts_rows) do
        def initialize(name:, function:, attribute: nil, counts_rows: false) = super
      end

      def initialize(relation)
        @relation = relation
        @aggregate_columns = nil
      end

      def aggregate_columns
        @aggregate_columns ||= @relation.select_values.filter_map { |value| classify(value) }
      end

      def delta_maintainable?
        single_table? && grouped? && !having? && distributive_aggregates? && aggregate_columns.any?(&:counts_rows)
      end

      def distributive_aggregates?
        aggregate_columns.any? && aggregate_columns.all? { |column| distributive?(column) }
      end

      def row_count_column
        aggregate_columns.find(&:counts_rows)
      end

      private

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

      def count_column(name, node)
        return Column.new(name: name, function: :count_distinct, attribute: attribute_name(node)) if node.distinct
        return Column.new(name: name, function: :count_star, counts_rows: true) if star?(node)

        attribute = attribute_name(node)
        Column.new(name: name, function: :count, attribute: attribute, counts_rows: not_null_column?(attribute))
      end

      def distributive?(column)
        case column.function
        # A SUM over a nullable column can be NULL, which a zero delta can't
        # distinguish from 0, so only NOT NULL sums are delta-maintainable.
        when :sum then !column.attribute.nil? && not_null_column?(column.attribute)
        when :count then !column.attribute.nil?
        when :count_star then true
        else false
        end
      end

      def attribute_name(node)
        inner = node.expressions.first
        inner.is_a?(::Arel::Attributes::Attribute) ? inner.name.to_s : nil
      end

      def star?(node)
        inner = node.expressions.first
        !!(inner.is_a?(::Arel::Nodes::SqlLiteral) && inner.to_s == "*")
      end

      def alias_name(value)
        right = value.right
        right.respond_to?(:name) ? right.name.to_s : right.to_s
      end

      def not_null_column?(attribute)
        return false if attribute.nil?

        column = @relation.klass.columns_hash[attribute]
        !column.nil? && !column.null
      end

      def single_table?
        @relation.joins_values.empty? && @relation.from_clause.value.nil?
      end

      def grouped?
        @relation.group_values.any?
      end

      def having?
        !@relation.having_clause.empty?
      end
    end
  end
end
