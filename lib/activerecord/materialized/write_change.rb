# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class WriteChange
      extend T::Sig

      Operation = T.type_alias { T.any(Symbol, String) }

      sig { returns(String) }
      attr_reader :table_name

      sig { returns(Operation) }
      attr_reader :operation

      sig { returns(T::Hash[String, T.untyped]) }
      attr_reader :attributes

      sig { returns(T::Hash[String, T.untyped]) }
      attr_reader :previous_attributes

      sig do
        params(
          table_name: String,
          operation: Operation,
          attributes: T::Hash[String, T.untyped],
          previous_attributes: T::Hash[String, T.untyped]
        ).void
      end
      def initialize(table_name:, operation:, attributes:, previous_attributes:)
        @table_name = table_name
        @operation = operation
        @attributes = attributes
        @previous_attributes = previous_attributes
      end

      sig { params(record: ::ActiveRecord::Base, operation: Operation).returns(WriteChange) }
      def self.from_record(record, operation)
        case operation.to_sym
        when :create
          from_create(record)
        when :update
          from_update(record)
        when :destroy
          from_destroy(record)
        else
          raise ArgumentError, "unsupported write operation: #{operation}"
        end
      end

      sig { params(record: ::ActiveRecord::Base).returns(WriteChange) }
      def self.from_create(record)
        new(
          table_name: record.class.table_name,
          operation: :create,
          attributes: stringify_keys(record.attributes),
          previous_attributes: {}
        )
      end

      sig { params(record: ::ActiveRecord::Base).returns(WriteChange) }
      def self.from_update(record)
        new(
          table_name: record.class.table_name,
          operation: :update,
          attributes: changed_values(record.saved_changes),
          previous_attributes: previous_values(record.saved_changes)
        )
      end

      sig { params(record: ::ActiveRecord::Base).returns(WriteChange) }
      def self.from_destroy(record)
        new(
          table_name: record.class.table_name,
          operation: :destroy,
          attributes: stringify_keys(record.attributes_in_database),
          previous_attributes: {}
        )
      end

      sig { params(changes: T::Hash[String, T::Array[T.untyped]]).returns(T::Hash[String, T.untyped]) }
      def self.changed_values(changes)
        changes.transform_values(&:last)
      end

      sig { params(changes: T::Hash[String, T::Array[T.untyped]]).returns(T::Hash[String, T.untyped]) }
      def self.previous_values(changes)
        changes.transform_values(&:first)
      end

      sig { params(values: T::Hash[T.any(String, Symbol), T.untyped]).returns(T::Hash[String, T.untyped]) }
      def self.stringify_keys(values)
        values.each_with_object({}) do |(key, value), result|
          result[key.to_s] = value
        end
      end

      private_class_method :from_create, :from_update, :from_destroy, :changed_values, :previous_values,
                           :stringify_keys
    end
  end
end
