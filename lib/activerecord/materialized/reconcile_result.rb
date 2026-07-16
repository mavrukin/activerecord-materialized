# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # The outcome of a {Reconciler} run: which partitions were found divergent and
    # repaired with scoped maintenance, and whether the run was deferred because a
    # refresh was already in flight (in which case nothing was changed — the next
    # scheduled tick reconciles).
    ReconcileResult = Data.define(
      :view_name,
      :mode,
      # The divergent partition keys reconciliation repaired (missing, extra, or mismatched).
      :repaired_keys,
      # True when a concurrent refresh deferred the run; the queued repair drains later.
      :deferred,
      # Set when a batch run (reconcile_all!/reconcile_stale!) caught an error for this
      # view, so one failing view doesn't abort reconciliation for the rest of the fleet.
      :error
    ) do
      def initialize(view_name:, mode:, repaired_keys:, deferred: false, error: nil) = super

      def repaired_partition_count
        repaired_keys.size
      end

      # Repaired real drift this run — divergence was found and applied, not deferred.
      def repaired?
        repaired_keys.any? && !deferred
      end

      def failed?
        !error.nil?
      end
    end
  end
end
