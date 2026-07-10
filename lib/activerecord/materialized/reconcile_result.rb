# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # The outcome of a {Reconciler} run: which partitions were found divergent and
    # repaired with scoped maintenance, and whether the run was deferred because a
    # refresh was already in flight (in which case nothing was changed — the next
    # scheduled tick reconciles).
    class ReconcileResult < T::Struct
      extend T::Sig

      const :view_name, String
      const :mode, Symbol
      # The divergent partition keys reconciliation repaired (missing, extra, or mismatched).
      const :repaired_keys, T::Array[T::Array[T.untyped]]
      # True when a concurrent refresh deferred the run; the queued repair drains later.
      const :deferred, T::Boolean, default: false
      # Set when a batch run (reconcile_all!/reconcile_stale!) caught an error for this
      # view, so one failing view doesn't abort reconciliation for the rest of the fleet.
      const :error, T.nilable(String), default: nil

      sig { returns(Integer) }
      def repaired_partition_count
        repaired_keys.size
      end

      # Repaired real drift this run — divergence was found and applied, not deferred.
      sig { returns(T::Boolean) }
      def repaired?
        repaired_keys.any? && !deferred
      end

      sig { returns(T::Boolean) }
      def failed?
        !error.nil?
      end
    end
  end
end
