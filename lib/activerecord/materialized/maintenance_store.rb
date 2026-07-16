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
        metadata.record_maintenance_payload!(combine(pending, delta).serialize)
      end

      def pending
        payload = metadata.maintenance_payload
        SummaryDelta.deserialize(payload) || MaintenanceDelta.deserialize(payload)
      end

      def pending_delta
        MaintenanceDelta.deserialize(metadata.maintenance_payload)
      end

      def consume_pending_delta!
        delta = pending_delta || MaintenanceDelta.full_partition
        clear!
        delta
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
