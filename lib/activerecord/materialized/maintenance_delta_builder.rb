# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class MaintenanceDeltaBuilder
      extend T::Sig

      sig { params(change: WriteChange, key_columns: T::Array[String]).void }
      def initialize(change, key_columns)
        @change = change
        @key_columns = key_columns
      end

      sig { returns(MaintenanceDelta) }
      def build
        return MaintenanceDelta.full_partition if @key_columns.empty?

        tuples = extract_tuples
        tuples.empty? ? MaintenanceDelta.full_partition : MaintenanceDelta.scoped(tuples.uniq)
      end

      private

      sig { returns(T::Array[T::Array[T.untyped]]) }
      def extract_tuples
        case @change.operation.to_sym
        when :create, :destroy
          tuple = key_tuple(@change.attributes)
          tuple ? [tuple] : []
        when :update
          tuples = []
          tuples << key_tuple(@change.attributes) if keys_present?(@change.attributes)
          tuples << key_tuple(@change.previous_attributes) if keys_present?(@change.previous_attributes)
          tuples.compact
        else
          []
        end
      end

      sig { params(attributes: T::Hash[String, T.untyped]).returns(T::Boolean) }
      def keys_present?(attributes)
        @key_columns.all? do |column|
          attributes.key?(column) || T.unsafe(attributes).key?(column.to_sym)
        end
      end

      sig { params(attributes: T::Hash[String, T.untyped]).returns(T.nilable(T::Array[T.untyped])) }
      def key_tuple(attributes)
        return nil unless keys_present?(attributes)

        @key_columns.map { |column| attribute_value(attributes, column) }
      end

      sig { params(attributes: T::Hash[String, T.untyped], column: String).returns(T.untyped) }
      def attribute_value(attributes, column)
        attributes[column] || T.unsafe(attributes)[column.to_sym]
      end
    end
  end
end
