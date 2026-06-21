# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class IncrementalMaintainer
      extend T::Sig

      sig { params(view_class: ViewClass).void }
      def initialize(view_class)
        @view_class = view_class
      end

      sig { params(_connection: Connection, _table_name: String).returns(Integer) }
      def maintain!(_connection, _table_name)
        delta = maintenance_store.consume_pending_delta!
        relation = resolve_maintenance_relation(delta)

        row_count = RelationCacheWriter.new(view_class).replace_partitions!(
          relation,
          key_tuples: delta.key_tuples,
          full_partition: delta.full_partition?
        )

        # On a cold view the maintained partitions are now materialized, so a
        # subsequent keyed read serves them from the cache.
        unless delta.full_partition? || view_class.materialized?
          PartitionState.new(view_class).mark_fresh!(delta.key_tuples)
        end

        row_count
      end

      private

      sig { returns(ViewClass) }
      attr_reader :view_class

      sig { returns(MaintenanceStore) }
      def maintenance_store
        MaintenanceStore.new(view_class)
      end

      sig { params(delta: MaintenanceDelta).returns(::ActiveRecord::Relation) }
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
