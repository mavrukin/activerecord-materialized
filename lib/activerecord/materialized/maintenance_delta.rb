# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class MaintenanceDelta
      extend T::Sig

      SCOPED = T.let(:scoped, Symbol)
      FULL = T.let(:full_partition, Symbol)

      sig { returns(Symbol) }
      attr_reader :scope

      sig { returns(T::Array[T::Array[String]]) }
      attr_reader :key_tuples

      sig { params(scope: Symbol, key_tuples: T::Array[T::Array[String]]).void }
      def initialize(scope:, key_tuples: [])
        @scope = scope
        @key_tuples = key_tuples
      end

      sig { params(key_tuples: T::Array[T::Array[String]]).returns(MaintenanceDelta) }
      def self.scoped(key_tuples)
        new(scope: SCOPED, key_tuples: key_tuples)
      end

      sig { returns(MaintenanceDelta) }
      def self.full_partition
        new(scope: FULL)
      end

      sig { returns(T::Boolean) }
      def full_partition?
        scope == FULL
      end

      sig { params(other: MaintenanceDelta).returns(MaintenanceDelta) }
      def merge(other)
        return self if other.full_partition?
        return other if full_partition?

        combined = (key_tuples + other.key_tuples).uniq
        self.class.scoped(combined)
      end

      sig { returns(T::Hash[String, T.untyped]) }
      def serialize
        {
          "scope" => scope.to_s,
          "key_tuples" => key_tuples
        }
      end

      sig { params(payload: T.nilable(T::Hash[String, T.untyped])).returns(T.nilable(MaintenanceDelta)) }
      def self.deserialize(payload)
        return nil if payload.blank?

        scope_name = payload["scope"]&.to_sym
        return nil if scope_name.nil?

        if scope_name == FULL
          full_partition
        else
          tuples = T.cast(payload["key_tuples"], T.nilable(T::Array[T::Array[String]])) || []
          scoped(tuples)
        end
      end
    end
  end
end
