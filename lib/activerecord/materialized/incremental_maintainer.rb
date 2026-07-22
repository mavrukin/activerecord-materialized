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
        # A widen (full_partition) on a warm view is a full recompute — the same scan as rebuild!, so
        # route it through the atomic build-and-swap instead of an in-place delete_all + re-insert. That
        # keeps readers on the old snapshot until an instant rename, rather than exposing an empty/locked
        # table mid-recompute. (A cold view can't reach here with full_partition: Refresher#maintainable?
        # declines it, #120. So this branch is always the warm full-recompute case.)
        return recompute_all! if delta.full_partition?

        apply_scoped_delta!(delta)
      end

      def recompute_all!
        RelationCacheWriter.new(view_class).atomic_swap!(full_source_relation)
      end

      def apply_scoped_delta!(delta)
        partition_state = PartitionState.new(view_class)
        cold_scoped = !view_class.materialized?
        # Capture the fresh-set epoch BEFORE the source read, so a widen committing during the read
        # advances the epoch and leaves this populate's mark un-served (the populate-vs-widen race, #120).
        generation = partition_state.current_generation if cold_scoped

        row_count = RelationCacheWriter.new(view_class).replace_partitions!(
          scoped_source_relation(delta.key_tuples),
          key_tuples: delta.key_tuples
        )

        # On a cold view the maintained partitions are now fresh, stamped with the captured epoch.
        partition_state.mark_fresh!(delta.key_tuples, generation: generation) if cold_scoped

        row_count
      end

      def maintenance_store
        MaintenanceStore.new(view_class)
      end

      # The whole-view source for a full recompute (the incremental override wins when configured).
      def full_source_relation
        view_class.incremental_source_override? ? view_class.resolved_incremental_source : view_class.resolved_source
      end

      # The source restricted to the affected partitions (the incremental override wins when configured;
      # it is already the maintainable relation, so it is not re-scoped here).
      def scoped_source_relation(key_tuples)
        return view_class.resolved_incremental_source if view_class.incremental_source_override?

        view_class.view_definition.partition_scope(key_tuples)
      end
    end
  end
end
