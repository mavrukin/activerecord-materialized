# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class MaintenanceStore
      extend T::Sig

      Pending = T.type_alias { T.any(SummaryDelta, MaintenanceDelta) }

      sig { params(view_class: ViewClass).void }
      def initialize(view_class)
        @view_class = view_class
      end

      # Accumulates either kind of pending maintenance: a SummaryDelta (delta
      # IVM) or a MaintenanceDelta (scoped recompute). A view's mode is fixed
      # within a maintenance window, so the existing pending (if any) is always
      # the same kind.
      sig { params(delta: Pending).void }
      def merge!(delta)
        current = pending
        merged = current.instance_of?(delta.class) ? T.unsafe(current).merge(delta) : delta
        metadata.record_maintenance_payload!(T.unsafe(merged).serialize)
      end

      sig { returns(T.nilable(Pending)) }
      def pending
        payload = metadata.maintenance_payload
        SummaryDelta.deserialize(payload) || MaintenanceDelta.deserialize(payload)
      end

      sig { returns(T.nilable(MaintenanceDelta)) }
      def pending_delta
        MaintenanceDelta.deserialize(metadata.maintenance_payload)
      end

      sig { returns(MaintenanceDelta) }
      def consume_pending_delta!
        delta = pending_delta || MaintenanceDelta.full_partition
        clear!
        delta
      end

      sig { void }
      def clear!
        metadata.clear_maintenance_payload!
      end

      private

      sig { returns(ViewClass) }
      attr_reader :view_class

      sig { returns(Metadata) }
      def metadata
        view_class.metadata
      end
    end
  end
end
