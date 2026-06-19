# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    module QueryExpressions
      extend T::Sig

      module_function

      sig { params(attribute: Arel::Attributes::Attribute, as: T.any(Symbol, String)).returns(Arel::Nodes::As) }
      def sum_as(attribute, as:)
        attribute.sum.as(as.to_s)
      end

      sig { params(attribute: Arel::Attributes::Attribute, as: T.any(Symbol, String)).returns(Arel::Nodes::As) }
      def avg_as(attribute, as:)
        attribute.average.as(as.to_s)
      end

      sig { params(attribute: Arel::Attributes::Attribute, as: T.any(Symbol, String)).returns(Arel::Nodes::As) }
      def min_as(attribute, as:)
        attribute.minimum.as(as.to_s)
      end

      sig { params(attribute: Arel::Attributes::Attribute, as: T.any(Symbol, String)).returns(Arel::Nodes::As) }
      def max_as(attribute, as:)
        attribute.maximum.as(as.to_s)
      end

      sig { params(as: T.any(Symbol, String)).returns(Arel::Nodes::As) }
      def count_all_as(as:)
        Arel.star.count.as(as.to_s)
      end

      sig { params(attribute: Arel::Attributes::Attribute, as: T.any(Symbol, String)).returns(Arel::Nodes::As) }
      def count_as(attribute, as:)
        attribute.count.as(as.to_s)
      end

      sig { params(attribute: Arel::Attributes::Attribute, as: T.any(Symbol, String)).returns(Arel::Nodes::As) }
      def count_distinct_as(attribute, as:)
        attribute.count(true).as(as.to_s)
      end

      sig { params(attribute: Arel::Attributes::Attribute).returns(Arel::Nodes::NamedFunction) }
      def length(attribute)
        Arel::Nodes::NamedFunction.new("LENGTH", [attribute])
      end

      sig { params(attribute: Arel::Attributes::Attribute, as: T.any(Symbol, String)).returns(Arel::Nodes::As) }
      def sum_length_as(attribute, as:)
        length(attribute).sum.as(as.to_s)
      end
    end
  end
end
