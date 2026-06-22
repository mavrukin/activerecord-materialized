# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Portable, aliased Arel aggregate helpers for building a view's
    # {ViewConfigurationClassMethods::ClassMethods#materialized_from source
    # relation} without raw SQL. `extend` it into a view (or any object) so the
    # helpers are available where you build the relation.
    #
    # @example
    #   class SalesByCategory < ActiveRecord::Materialized::View
    #     extend ActiveRecord::Materialized::QueryExpressions
    #     materialized_from do
    #       items = Item.arel_table
    #       Item.group(:category).select(
    #         items[:category],
    #         sum_as(items[:amount], as: :revenue),
    #         count_all_as(as: :order_count)
    #       )
    #     end
    #   end
    module QueryExpressions
      extend T::Sig

      module_function

      # @return [Arel::Nodes::As] +SUM(attribute) AS <as>+
      sig { params(attribute: Arel::Attributes::Attribute, as: T.any(Symbol, String)).returns(Arel::Nodes::As) }
      def sum_as(attribute, as:)
        attribute.sum.as(as.to_s)
      end

      # @return [Arel::Nodes::As] +AVG(attribute) AS <as>+
      sig { params(attribute: Arel::Attributes::Attribute, as: T.any(Symbol, String)).returns(Arel::Nodes::As) }
      def avg_as(attribute, as:)
        attribute.average.as(as.to_s)
      end

      # @return [Arel::Nodes::As] +MIN(attribute) AS <as>+
      sig { params(attribute: Arel::Attributes::Attribute, as: T.any(Symbol, String)).returns(Arel::Nodes::As) }
      def min_as(attribute, as:)
        attribute.minimum.as(as.to_s)
      end

      # @return [Arel::Nodes::As] +MAX(attribute) AS <as>+
      sig { params(attribute: Arel::Attributes::Attribute, as: T.any(Symbol, String)).returns(Arel::Nodes::As) }
      def max_as(attribute, as:)
        attribute.maximum.as(as.to_s)
      end

      # @return [Arel::Nodes::As] +COUNT(*) AS <as>+ — a trustworthy per-partition row count
      sig { params(as: T.any(Symbol, String)).returns(Arel::Nodes::As) }
      def count_all_as(as:)
        Arel.star.count.as(as.to_s)
      end

      # @return [Arel::Nodes::As] +COUNT(attribute) AS <as>+ (non-null values)
      sig { params(attribute: Arel::Attributes::Attribute, as: T.any(Symbol, String)).returns(Arel::Nodes::As) }
      def count_as(attribute, as:)
        attribute.count.as(as.to_s)
      end

      # @return [Arel::Nodes::As] +COUNT(DISTINCT attribute) AS <as>+
      sig { params(attribute: Arel::Attributes::Attribute, as: T.any(Symbol, String)).returns(Arel::Nodes::As) }
      def count_distinct_as(attribute, as:)
        attribute.count(true).as(as.to_s)
      end

      # @return [Arel::Nodes::NamedFunction] +LENGTH(attribute)+
      sig { params(attribute: Arel::Attributes::Attribute).returns(Arel::Nodes::NamedFunction) }
      def length(attribute)
        Arel::Nodes::NamedFunction.new("LENGTH", [attribute])
      end

      # @return [Arel::Nodes::As] +SUM(LENGTH(attribute)) AS <as>+
      sig { params(attribute: Arel::Attributes::Attribute, as: T.any(Symbol, String)).returns(Arel::Nodes::As) }
      def sum_length_as(attribute, as:)
        length(attribute).sum.as(as.to_s)
      end
    end
  end
end
