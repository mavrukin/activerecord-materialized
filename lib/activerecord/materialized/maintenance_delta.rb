# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Pending scoped-recompute maintenance: the affected partition keys, or a full-partition marker.
    #
    # @api private
    class MaintenanceDelta
      SCOPED = :scoped
      FULL = :full_partition

      attr_reader :scope, :key_tuples

      def initialize(scope:, key_tuples: [])
        @scope = scope
        @key_tuples = key_tuples
      end

      def self.scoped(key_tuples)
        new(scope: SCOPED, key_tuples: key_tuples)
      end

      def self.full_partition
        new(scope: FULL)
      end

      def full_partition?
        scope == FULL
      end

      # How many distinct partitions this pending maintenance tracks. A
      # full-partition recompute tracks none — it is already the collapsed form.
      def tracked_partition_count
        full_partition? ? 0 : key_tuples.size
      end

      def merge(other)
        return other if other.full_partition?
        return self if full_partition?

        combined = (key_tuples + other.key_tuples).uniq
        self.class.scoped(combined)
      end

      def serialize
        {
          "scope" => scope.to_s,
          "key_tuples" => key_tuples
        }
      end

      def self.deserialize(payload)
        return nil if payload.blank?

        scope_name = payload["scope"]&.to_sym
        return nil if scope_name.nil?

        if scope_name == FULL
          full_partition
        else
          tuples = payload["key_tuples"] || []
          scoped(tuples)
        end
      end
    end
  end
end
