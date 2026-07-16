# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Restricts a relation to a set of partition key tuples, given the Arel key
    # attributes already resolved to their tables. Handles single- and multi-column
    # keys, and matches a NULL key with IS NULL (SQL's `IN (...)` never matches NULL).
    #
    # @api private
    class PartitionFilter
      def initialize(attributes, key_tuples)
        @attributes = attributes
        @key_tuples = key_tuples
      end

      def apply(scope)
        @attributes.size > 1 ? multi_column(scope) : scope.where(single_column_predicate)
      end

      private

      # OR in an `IS NULL` when a NULL partition key is requested (a nullable GROUP
      # BY column's NULL group), which `IN (...)` would otherwise skip.
      def single_column_predicate
        attribute = @attributes.fetch(0)
        values = @key_tuples.map(&:first)
        present = values.compact
        in_predicate = attribute.in(present) unless present.empty?
        return in_predicate unless values.size > present.size

        null_predicate = attribute.eq(nil)
        in_predicate ? in_predicate.or(null_predicate) : null_predicate
      end

      def multi_column(scope)
        @key_tuples.reduce(nil) do |merged_scope, tuple|
          branch = @attributes.each_with_index.reduce(scope) do |relation, (attribute, index)|
            relation.where(attribute.eq(tuple[index]))
          end
          merged_scope.nil? ? branch : merged_scope.or(branch)
        end
      end
    end
  end
end
