# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Routes a read to the cache table or to the cold-read fallback
    # (populate-on-read for keyed reads), emitting the read instrumentation event
    # for whichever path it serves.
    #
    # @api private
    class ReadRouter
      def initialize(view_class)
        @view_class = view_class
      end

      # Routing for reads with no partition predicate to exploit.
      def scope
        @view_class.materialized? ? cache : cold
      end

      # Per-partition fast path for keyed reads: serve fresh partitions from the
      # cache, otherwise read through and enqueue maintenance (populate-on-read).
      def partition_scope(args)
        return cache if @view_class.materialized?

        keys = PartitionState.keys_from(@view_class, args)
        return cold if keys.nil?
        return cache if PartitionState.new(@view_class).all_fresh?(keys)

        enqueue_partition_maintenance(keys)
        cold
      end

      private

      def cache
        Instrumentation.read(@view_class, source: :cache)
        @view_class.unscoped
      end

      def cold
        Instrumentation.read(@view_class, source: @view_class.resolved_cold_read_strategy)
        ColdRead.new(@view_class).scope
      end

      def enqueue_partition_maintenance(keys)
        MaintenanceStore.new(@view_class).merge!(MaintenanceDelta.scoped(keys))
        RefreshScheduler.schedule(@view_class)
      end
    end
  end
end
