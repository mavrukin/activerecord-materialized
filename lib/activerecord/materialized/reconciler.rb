# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Bounds a view's staleness in time: verifies its materialized contents against
    # the source (via {DataVerifier}) and repairs whatever the change source missed,
    # using SCOPED maintenance — never a full rebuild. Meant to run on a schedule as a
    # backstop for writes any change source can miss (a bulk/raw write, a dropped or
    # lagging CDC event).
    #
    # Safe alongside normal refresh. It drains pending maintenance first, so remaining
    # drift is genuinely missed writes rather than un-applied maintenance, then repairs
    # through the same guarded, transactional maintenance path. When a refresh is
    # already in flight it defers to the next tick rather than verifying a cache
    # mid-mutation or racing that cycle's payload — so it can neither corrupt the cache
    # nor double-maintain.
    #
    # @api private
    class Reconciler
      extend T::Sig

      sig { params(view_class: ViewClass, mode: Symbol, sample: T.nilable(Numeric)).void }
      def initialize(view_class, mode: :checksum, sample: nil)
        @view_class = view_class
        @mode = mode
        @sample = sample
      end

      sig { returns(ReconcileResult) }
      def reconcile!
        divergent = T.let([], T::Array[T::Array[T.untyped]])
        return emit(build) unless @view_class.materialized? # cold view: no cache to verify or repair

        @view_class.refresh! # drain pending maintenance so any remaining drift is genuine
        divergent = detect_drift
        repair!(divergent) unless divergent.empty?
        mark_reconciled!(divergent)
        emit(build(repaired_keys: divergent))
      rescue Refresher::AlreadyRefreshingError
        # A live refresh owns the cycle; the scoped repair we queued (if any) drains on
        # that cycle or the next tick. Defer without corrupting or double-maintaining.
        emit(build(repaired_keys: divergent || [], deferred: true))
      end

      private

      sig { returns(T::Array[T::Array[T.untyped]]) }
      def detect_drift
        DataVerifier.new(@view_class, mode: @mode, sample: @sample).verify.divergent_keys
      end

      # Queue a scoped recompute of the divergent partitions and apply it in place —
      # re-aggregating missing/mismatched partitions and dropping extra ones uniformly.
      sig { params(divergent: T::Array[T::Array[T.untyped]]).void }
      def repair!(divergent)
        MaintenanceStore.new(@view_class).merge!(MaintenanceDelta.scoped(divergent))
        @view_class.refresh!
      end

      sig { params(divergent: T::Array[T::Array[T.untyped]]).void }
      def mark_reconciled!(divergent)
        Metadata::Reconciliation.mark!(@view_class.metadata, repaired_partition_count: divergent.size)
      end

      sig { params(repaired_keys: T::Array[T::Array[T.untyped]], deferred: T::Boolean).returns(ReconcileResult) }
      def build(repaired_keys: [], deferred: false)
        ReconcileResult.new(
          view_name: @view_class.view_key, mode: @mode, repaired_keys: repaired_keys, deferred: deferred
        )
      end

      sig { params(outcome: ReconcileResult).returns(ReconcileResult) }
      def emit(outcome)
        Instrumentation.reconcile(
          @view_class,
          mode: outcome.mode, repaired_partition_count: outcome.repaired_partition_count,
          deferred: outcome.deferred
        )
        outcome
      end
    end
  end
end
