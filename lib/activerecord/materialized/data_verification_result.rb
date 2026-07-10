# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # The outcome of a {DataVerifier} run: the partition keys whose materialized
    # contents diverge from the source relation, plus how much was checked.
    class DataVerificationResult < T::Struct
      extend T::Sig

      const :view_name, String
      const :mode, Symbol
      const :total_partition_count, Integer
      const :checked_partition_count, Integer
      # In the source relation but absent from the cache.
      const :missing_keys, T::Array[T::Array[T.untyped]]
      # In the cache but absent from the source relation.
      const :extra_keys, T::Array[T::Array[T.untyped]]
      # Present in both, but the partition's cache contents diverge. In +:full+ and
      # +:checksum+ this means the value columns differ; in every mode (including
      # +:row_count+) it also flags a partition the cache holds a different *number*
      # of rows for than the source — a duplicated or lost row within the partition.
      const :mismatched_keys, T::Array[T::Array[T.untyped]]

      # A clean result covering nothing — for a view that isn't materialized yet.
      sig { params(view_name: String, mode: Symbol).returns(DataVerificationResult) }
      def self.empty(view_name:, mode:)
        new(
          view_name: view_name, mode: mode, total_partition_count: 0, checked_partition_count: 0,
          missing_keys: [], extra_keys: [], mismatched_keys: []
        )
      end

      sig { returns(T::Boolean) }
      def drifted?
        missing_keys.any? || extra_keys.any? || mismatched_keys.any?
      end

      # Every diverging partition key, however it diverged — the set a reconciliation
      # re-maintains (see {Reconciler}).
      sig { returns(T::Array[T::Array[T.untyped]]) }
      def divergent_keys
        (missing_keys + extra_keys + mismatched_keys).uniq
      end
    end
  end
end
