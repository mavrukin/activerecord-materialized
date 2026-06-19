# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class MaintenanceStore
      extend T::Sig

      sig { params(view_class: ViewClass).void }
      def initialize(view_class)
        @view_class = view_class
      end

      sig { params(delta: MaintenanceDelta).void }
      def merge!(delta)
        pending = pending_delta
        merged = pending.nil? ? delta : pending.merge(delta)
        metadata.record_maintenance_payload!(merged.serialize)
      end

      sig { returns(T.nilable(MaintenanceDelta)) }
      def pending_delta
        MaintenanceDelta.deserialize(metadata.maintenance_payload)
      end

      sig { returns(MaintenanceDelta) }
      def consume_pending_delta!
        delta = pending_delta || MaintenanceDelta.full_partition
        metadata.clear_maintenance_payload!
        delta
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
