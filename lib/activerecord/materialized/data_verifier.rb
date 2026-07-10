# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Detects DATA drift — the materialized cache diverging from what the source
    # relation would produce right now — as opposed to {SchemaVerifier}'s schema
    # drift. Stateless: it only reads and compares.
    #
    # Modes trade cost for depth:
    # * +:row_count+ — which partitions exist (missing/extra); cheapest.
    # * +:checksum+  — a per-partition digest of the value columns.
    # * +:full+      — the value columns exactly.
    #
    # +sample:+ (Integer count / Float fraction) value-checks a random subset of
    # partitions for large views; a sample covering every partition runs exhaustive.
    #
    # Covers grouped/aggregate views whose GROUP BY keys map to projected columns
    # (the incremental-maintenance target). A non-grouped view, or one whose group
    # key can't be matched to a projected column, is skipped (an empty result).
    class DataVerifier
      extend T::Sig

      # Raised (by {Materialized.verify_data!}) when a view's contents have drifted.
      class DataDriftError < StandardError; end

      MODES = T.let(%i[row_count checksum full].freeze, T::Array[Symbol])

      sig { params(view_class: ViewClass, mode: Symbol, sample: T.nilable(Numeric)).void }
      def initialize(view_class, mode: :checksum, sample: nil)
        raise ArgumentError, "unknown data-verification mode #{mode.inspect}" unless MODES.include?(mode)

        @view_class = view_class
        @mode = mode
        @sample = sample
      end

      sig { returns(DataVerificationResult) }
      def verify
        return empty_result unless verifiable?
        return verify_exhaustive if @sample.nil?

        keys = cache_partition_keys
        size = sample_size(keys.size)
        return verify_exhaustive if size >= keys.size # a sample covering everything is exhaustive
        return empty_result if size.zero?             # sample: 0 => nothing checked

        verify_sampled(Array(keys.sample(size)), keys.size)
      end

      private

      # Compares every partition, so it detects missing, extra, and mismatched.
      sig { returns(DataVerificationResult) }
      def verify_exhaustive
        cache = snapshot(@view_class.unscoped)
        source = snapshot(@view_class.resolved_source)
        total = (cache.keys | source.keys).size # every partition on either side
        build_result(cache, source, total: total, checked: total, exhaustive: true)
      end

      # A value-drift probe over a random subset of materialized partitions. It
      # cannot detect missing (source-only) partitions — that needs a full source
      # scan — so it never reports them.
      sig { params(checked: T::Array[T::Array[T.untyped]], total: Integer).returns(DataVerificationResult) }
      def verify_sampled(checked, total)
        cache = snapshot(view_definition.partition_scope_on(@view_class, checked))
        source = snapshot(view_definition.partition_scope(checked))
        build_result(cache, source, total: total, checked: checked.size, exhaustive: false)
      end

      sig do
        params(
          cache: T::Hash[T::Array[T.untyped], T.untyped], source: T::Hash[T::Array[T.untyped], T.untyped],
          total: Integer, checked: Integer, exhaustive: T::Boolean
        ).returns(DataVerificationResult)
      end
      def build_result(cache, source, total:, checked:, exhaustive:)
        shared = cache.keys & source.keys
        DataVerificationResult.new(
          view_name: @view_class.view_key, mode: @mode,
          total_partition_count: total, checked_partition_count: checked,
          missing_keys: exhaustive ? source.keys - cache.keys : [],
          extra_keys: cache.keys - source.keys,
          # Signature tallies differ on value drift and on a duplicated cache row
          # (row_count's tally is of row presence, so it catches duplicates too).
          mismatched_keys: shared.reject { |key| cache[key] == source[key] }
        )
      end

      sig { params(relation: ::ActiveRecord::Relation).returns(T::Hash[T::Array[T.untyped], T.untyped]) }
      def snapshot(relation)
        PartitionSnapshot.new(@view_class, key_columns, projected_columns - key_columns, @mode).of(relation)
      end

      # Verifiable when the view is a materialized aggregate whose group keys map to
      # projected columns and whose cache table actually has those columns (a
      # schema-drifted cache is skipped — run `verify_schema!` for that).
      sig { returns(T::Boolean) }
      def verifiable?
        keys = view_definition.group_key_columns
        @view_class.materialized? && keys.any? && key_columns.size == keys.size &&
          (projected_columns - @view_class.column_names).empty?
      end

      # Distinct group-key tuples in the cache — the population a sample is drawn from.
      # `distinct` dedups in the database, so only one row per partition crosses into
      # Ruby; the random draw stays in Ruby because a DB-side random order is neither an
      # ActiveRecord primitive nor portable across adapters. `pluck` returns scalars for
      # a single key (wrapped to 1-tuples so a NULL key becomes [nil], not the [] that
      # Array(nil) would give) and tuples for a composite key.
      sig { returns(T::Array[T::Array[T.untyped]]) }
      def cache_partition_keys
        values = @view_class.unscoped.distinct.pluck(*key_columns)
        key_columns.one? ? values.zip : values
      end

      # GROUP BY keys as their projected/cache column names (qualifier stripped), so a
      # joined key like "authors.country" matches the projected "country".
      sig { returns(T::Array[String]) }
      def key_columns
        @key_columns ||= T.let(
          view_definition.group_key_columns.filter_map { |column| projected_column_for(column) },
          T.nilable(T::Array[String])
        )
      end

      sig { params(column: String).returns(T.nilable(String)) }
      def projected_column_for(column)
        return column if projected_columns.include?(column)

        stripped = T.must(column.split(".").last)
        projected_columns.include?(stripped) ? stripped : nil
      end

      sig { returns(T::Array[String]) }
      def projected_columns
        @projected_columns ||= T.let(
          CacheTableSchema.column_definitions(@view_class.connection, @view_class.resolved_source).map(&:name),
          T.nilable(T::Array[String])
        )
      end

      sig { returns(ViewDefinition) }
      def view_definition
        @view_definition ||= T.let(@view_class.view_definition, T.nilable(ViewDefinition))
      end

      sig { params(total: Integer).returns(Integer) }
      def sample_size(total)
        sample = @sample
        return total if sample.nil?

        size = sample.is_a?(Float) ? (total * sample).ceil : sample.to_i
        size.clamp(0, total)
      end

      sig { returns(DataVerificationResult) }
      def empty_result
        DataVerificationResult.empty(view_name: @view_class.view_key, mode: @mode)
      end
    end
  end
end
