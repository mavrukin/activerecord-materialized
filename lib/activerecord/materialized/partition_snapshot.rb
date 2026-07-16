# frozen_string_literal: true

require "digest"

module ActiveRecord
  module Materialized
    # Reads a relation (via ActiveRecord, not raw SQL) into
    # { group-key tuple => value-signature tally } for {DataVerifier}.
    #
    # Both keys and values are cast through the *cache model's* own attribute types,
    # so the cache and the recomputed source are compared in a single type system —
    # an integer, string, date, or scaled-decimal column can't masquerade as drift
    # just because the two sides read it through different type casts. (An un-scaled
    # decimal aggregate can still differ in trailing float precision; give such a
    # column an explicit scale to compare it soundly.)
    #
    # Rows are tallied per key, so two cache rows for one partition are detected as a
    # count difference rather than silently collapsed.
    #
    # @api private
    class PartitionSnapshot
      SEPARATOR = "\x1f" # ASCII unit separator between digested values

      def initialize(model, key_columns, value_columns, mode)
        @model = model
        @key_columns = key_columns
        @value_columns = value_columns
        @mode = mode
      end

      def of(relation)
        relation.to_a
                .group_by { |record| key_tuple(record) }
                .transform_values { |records| records.map { |record| value_signature(record) }.tally }
      end

      private

      def key_tuple(record)
        @key_columns.map { |column| cast(column, record[column]) }
      end

      def value_signature(record)
        return nil if @mode == :row_count

        values = @value_columns.map { |column| cast(column, record[column]) }
        @mode == :checksum ? Digest::MD5.hexdigest(values.map(&:inspect).join(SEPARATOR)) : values
      end

      # Cast through the cache model's declared type so the cache value and the source
      # recompute (read through a different type system) normalize identically.
      def cast(column, value)
        @model.type_for_attribute(column).cast(value)
      end
    end
  end
end
