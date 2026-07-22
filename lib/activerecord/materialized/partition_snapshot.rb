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
    # just because the two sides read it through different type casts. A float
    # aggregate is additionally canonicalized to a fixed significance, since an
    # order-dependent SUM/AVG can differ from a re-aggregation in the last bit without
    # any real drift (see {FLOAT_SIGNIFICANT_DIGITS}).
    #
    # Rows are tallied per key, so two cache rows for one partition are detected as a
    # count difference rather than silently collapsed.
    #
    # @api private
    class PartitionSnapshot
      SEPARATOR = "\x1f" # ASCII unit separator between digested values

      # Significant digits a float aggregate is rounded to before comparison. A SUM/AVG over a float
      # column is order-dependent — the DB may re-aggregate base rows in a different order than the
      # maintained value accumulated, so the two differ in the last bit (0.1+0.2+0.3 => 0.6000000000000001
      # but 0.3+0.2+0.1 => 0.6). Rounding to a fixed significance absorbs that float noise so it does not
      # read as data drift, while any real divergence (a missed write moves the value by far more than a
      # ULP) is still caught. Integer/COUNT and fixed-scale decimal columns already compare exactly after
      # the type cast, so this only touches floats. ~12 of a double's ~15-16 significant digits leaves a
      # safe margin for accumulated rounding without masking a meaningful difference.
      FLOAT_SIGNIFICANT_DIGITS = 12

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

      # Cast through the cache model's declared type so the cache value and the source recompute (read
      # through a different type system) normalize identically, then canonicalize a float to a fixed
      # significance so order-dependent SUM/AVG rounding does not read as drift (see FLOAT_SIGNIFICANT_DIGITS).
      def cast(column, value)
        canonicalize_float(@model.type_for_attribute(column).cast(value))
      end

      # Round a float to FLOAT_SIGNIFICANT_DIGITS significant digits (relative, so it works at any
      # magnitude); non-floats — integers, fixed-scale decimals, strings — pass through untouched.
      def canonicalize_float(value)
        return value unless value.is_a?(Float)
        return value unless value.finite? && !value.zero?

        magnitude = Math.log10(value.abs).floor
        value.round(FLOAT_SIGNIFICANT_DIGITS - 1 - magnitude)
      end
    end
  end
end
