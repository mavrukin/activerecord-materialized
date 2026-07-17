# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Hot-path scoped recompute: deletes and re-aggregates only the affected partitions in place.
    #
    # @api private
    class IncrementalMaintainer
      def initialize(view_class)
        @view_class = view_class
      end

      def maintain!(_connection, _table_name)
        delta = maintenance_store.consume_pending_delta!
        return view_class.unscoped.count if delta.nil? # another cross-process cycle consumed it — no-op

        apply_delta!(delta)
      end

      private

      attr_reader :view_class

      def apply_delta!(delta)
        row_count = RelationCacheWriter.new(view_class).replace_partitions!(
          resolve_maintenance_relation(delta),
          key_tuples: delta.key_tuples,
          full_partition: delta.full_partition?
        )

        # On a cold view the maintained partitions are now fresh.
        unless delta.full_partition? || view_class.materialized?
          PartitionState.new(view_class).mark_fresh!(delta.key_tuples)
        end

        row_count
      end

      def maintenance_store
        MaintenanceStore.new(view_class)
      end

      def resolve_maintenance_relation(delta)
        if view_class.incremental_source_override?
          view_class.resolved_incremental_source
        elsif delta.full_partition?
          view_class.resolved_source
        else
          view_class.view_definition.partition_scope(delta.key_tuples)
        end
      end
    end
  end
end
