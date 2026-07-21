# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Persists a view's pending maintenance (a delta or a scope) in its metadata row.
    #
    # @api private
    class MaintenanceStore
      def initialize(view_class)
        @view_class = view_class
      end

      # Accumulates pending maintenance of either kind. A view's mode is fixed
      # within a window, so existing pending is always the same kind. Once the
      # tracked partitions exceed the configured cap, the payload collapses to a
      # single full recompute, so a bulk write spanning many partitions stays
      # O(1) per write instead of re-serializing an ever-growing blob.
      def merge!(delta)
        combined = combine(pending, delta)
        return drop_cold_full_recompute! if cold_full_recompute?(combined)

        metadata.record_maintenance_payload!(combined.serialize)
      end

      def pending
        payload = metadata.maintenance_payload
        SummaryDelta.deserialize(payload) || MaintenanceDelta.deserialize(payload)
      end

      def pending_delta
        MaintenanceDelta.deserialize(metadata.maintenance_payload)
      end

      # Atomically consume the pending scoped delta under a row lock on the metadata row, so two
      # cross-process cycles can't both consume it and recompute the same partition twice — which
      # duplicated rows on Postgres (no unique constraint, no gap locks under READ COMMITTED). Whoever
      # clears the payload owns the delta; a loser reads an empty payload and gets nil (a benign
      # no-op). Returns the delta, or nil. Unlike the additive summary path (which applies inside its
      # lock for crash-atomicity), the scoped recompute is idempotent (delete + re-aggregate), so the
      # caller applies OUTSIDE this lock, keeping it short; a crash between consume and apply loses the
      # delta, which self-healing reconciliation (#64) repairs on the next tick.
      def consume_pending_delta!
        metadata.record.with_lock do # blocking FOR UPDATE on the metadata row + a transaction
          delta = pending_delta
          next nil if delta.nil?

          clear!
          delta
        end
      end

      # Atomically consume the pending SummaryDelta and apply it under a row lock on the metadata
      # row, so concurrent cycles across servers can't apply the same additive delta twice. Yields
      # the delta to the block (which applies it) inside the locked transaction, so a failed apply
      # rolls back the clear and the delta is retried. Returns the block's result, or nil when another
      # cycle already consumed it — the loser blocks on the lock, then reads an empty payload (a
      # benign no-op). DML-only (no DDL/callbacks), so the lock holds for the whole critical section.
      def with_consumed_summary_delta
        metadata.record.with_lock do # blocking FOR UPDATE on the metadata row + a transaction
          delta = SummaryDelta.deserialize(metadata.maintenance_payload)
          next nil if delta.nil?

          clear!
          yield delta
        end
      end

      def clear!
        metadata.clear_maintenance_payload!
      end

      private

      def combine(current, delta)
        return delta if current.nil?
        return current if recompute_all?(current) # terminal: absorb everything
        # Different kinds can't merge (a summary delta meeting a scoped recompute — e.g.
        # reconcile's repair racing a callback write); widen to a full recompute rather
        # than dropping either side's pending maintenance.
        return MaintenanceDelta.full_partition unless current.instance_of?(delta.class)

        merged = current.merge(delta)
        oversized?(merged) ? MaintenanceDelta.full_partition : merged
      end

      def recompute_all?(pending)
        pending.is_a?(MaintenanceDelta) && pending.full_partition?
      end

      # A cold view can't apply a full-partition recompute (Refresher#maintainable? skips it) and storing
      # one gums up the payload: combine's terminal absorb (see #recompute_all?) then swallows every later
      # scoped read-miss delta, so populate-on-read never repopulates. Every cold widen funnels through
      # merge! — an ingested widening write, DependencyRegistry.mark_dirty_for_tables!, or a scoped payload
      # that overflows max_tracked_partitions inside #combine — so this one guard covers them all. The
      # cheap in-memory recompute_all? short-circuits before materialized?, so the scoped hot path is free.
      def cold_full_recompute?(combined)
        recompute_all?(combined) && !view_class.materialized?
      end

      # Drop the un-appliable recompute and invalidate the whole fresh set so every partition falls
      # through to the source until a read-miss repopulates it. Reset first, then clear: a crash between
      # the two leaves reads correct-by-fallback with only an un-appliable payload the next merge! re-drops.
      def drop_cold_full_recompute!
        PartitionState.new(view_class).reset!
        clear!
      end

      def oversized?(merged)
        merged.tracked_partition_count > ActiveRecord::Materialized.configuration.max_tracked_partitions
      end

      attr_reader :view_class

      def metadata
        view_class.metadata
      end
    end
  end
end
