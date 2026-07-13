# frozen_string_literal: true

module BenchmarkSupport
  # Order-independent equality of two ActiveRecord result sets, ignoring a cache
  # table's surrogate +id+ (the grouped source query has no counterpart for it) and
  # comparing only the columns the two sides share. Shared by the demo's raw-vs-view
  # comparison and the CDC scenario's convergence check, so "did the materialized
  # result match the source?" is defined in exactly one place.
  module ResultComparison
    IGNORED_COLUMNS = ["id"].freeze

    module_function

    def equivalent?(left, right)
      return false if left.size != right.size

      columns = (attribute_keys(left) & attribute_keys(right)) - IGNORED_COLUMNS
      normalize(left, columns) == normalize(right, columns)
    end

    def attribute_keys(records)
      records.first&.attributes&.keys || []
    end

    def normalize(records, columns)
      records.map { |record| record.attributes.values_at(*columns) }.sort_by(&:to_s)
    end
  end
end
