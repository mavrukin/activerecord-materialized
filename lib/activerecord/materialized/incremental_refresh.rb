# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Runs one incremental-maintenance pass for a view, choosing the summary-delta
    # or scoped-recompute path from the pending maintenance and annotating the
    # refresh instrumentation payload with the mode and partitions it touched.
    #
    # @api private
    class IncrementalRefresh
      extend T::Sig

      sig { params(view_class: ViewClass, payload: T::Hash[Symbol, T.untyped]).void }
      def initialize(view_class, payload)
        @view_class = view_class
        @payload = payload
      end

      sig { returns(Integer) }
      def call
        ensure_cache_table!
        store = MaintenanceStore.new(@view_class)
        pending = store.pending
        @payload[:mode] = mode(pending)
        @payload[:partition_count] = partition_count(pending)
        apply!(store, pending)
      end

      private

      sig { params(store: MaintenanceStore, pending: T.nilable(MaintenanceStore::Pending)).returns(Integer) }
      def apply!(store, pending)
        if pending.is_a?(SummaryDelta)
          store.clear!
          return DeltaMaintainer.new(@view_class).apply!(pending)
        end

        IncrementalMaintainer.new(@view_class).maintain!(@view_class.connection, @view_class.table_name)
      end

      sig { params(pending: T.nilable(MaintenanceStore::Pending)).returns(Symbol) }
      def mode(pending)
        pending.is_a?(SummaryDelta) ? :summary_delta : :scoped_recompute
      end

      # Partitions this pass recomputes; nil when it widened to a full recompute.
      sig { params(pending: T.nilable(MaintenanceStore::Pending)).returns(T.nilable(Integer)) }
      def partition_count(pending)
        return pending.tracked_partition_count if pending.is_a?(SummaryDelta)
        return nil unless pending.is_a?(MaintenanceDelta)

        pending.full_partition? ? nil : pending.key_tuples.size
      end

      # Cheap DDL so partition maintenance has somewhere to write — never a populate.
      sig { void }
      def ensure_cache_table!
        return if @view_class.table_exists?

        CacheTableSchema.ensure_table!(@view_class, @view_class.resolved_source)
      end
    end
  end
end
