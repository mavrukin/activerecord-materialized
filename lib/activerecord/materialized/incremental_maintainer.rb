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

        if relation
          RelationCacheWriter.new(view_class).replace_partitions!(
            relation,
            key_tuples: delta.key_tuples,
            full_partition: delta.full_partition?
          )
        else
          SqlCacheWriter.new(view_class).replace_partitions!(
            resolve_maintenance_sql(delta),
            key_tuples: delta.key_tuples,
            full_partition: delta.full_partition?
          )
        end
      end

      private

      sig { returns(ViewClass) }
      attr_reader :view_class

      sig { returns(MaintenanceStore) }
      def maintenance_store
        MaintenanceStore.new(view_class)
      end

      sig { params(delta: MaintenanceDelta).returns(T.nilable(::ActiveRecord::Relation)) }
      def resolve_maintenance_relation(delta)
        if view_class.incremental_source_override?
          coerce_relation(view_class.resolved_incremental_source)
        elsif delta.full_partition?
          coerce_relation(view_class.resolved_source)
        else
          view_class.view_definition.partition_scope(delta.key_tuples)
        end
      end

      sig { params(delta: MaintenanceDelta).returns(String) }
      def resolve_maintenance_sql(delta)
        if view_class.incremental_source_override?
          view_class.resolved_incremental_sql
        elsif delta.full_partition?
          view_class.resolved_source_sql
        else
          view_class.view_definition.scoped_source_sql(delta.key_tuples)
        end
      end

      sig { params(source: T.untyped).returns(T.nilable(::ActiveRecord::Relation)) }
      def coerce_relation(source)
        source if source.is_a?(::ActiveRecord::Relation)
      end
    end
  end
end
