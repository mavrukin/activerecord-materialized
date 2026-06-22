# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # A committed write to a dependency table, captured as full before/after
    # attribute snapshots (string-keyed). Snapshots are complete — not just the
    # changed columns — so maintenance can determine the affected partition and
    # compute aggregate deltas even when the GROUP BY key or a summed column did
    # not change in the write.
    class WriteChange
      extend T::Sig

      Operation = T.type_alias { T.any(Symbol, String) }
      Attributes = T.type_alias { T::Hash[String, T.untyped] }

      sig { returns(String) }
      attr_reader :table_name

      sig { returns(Operation) }
      attr_reader :operation

      sig { returns(Attributes) }
      attr_reader :before

      sig { returns(Attributes) }
      attr_reader :after

      sig { params(table_name: String, operation: Operation, before: Attributes, after: Attributes).void }
      def initialize(table_name:, operation:, before:, after:)
        @table_name = table_name
        @operation = operation
        @before = before
        @after = after
      end

      sig { params(record: ::ActiveRecord::Base, operation: Operation).returns(WriteChange) }
      def self.from_record(record, operation)
        table_name = record.class.table_name
        case operation.to_sym
        when :create
          new(table_name: table_name, operation: :create, before: {}, after: stringify_keys(record.attributes))
        when :update
          new(table_name: table_name, operation: :update, before: old_attributes(record),
              after: stringify_keys(record.attributes))
        when :destroy
          # attributes_in_database is emptied once the row is gone, so use the
          # in-memory attributes to keep the destroyed row's values.
          new(table_name: table_name, operation: :destroy, before: stringify_keys(record.attributes), after: {})
        else
          raise ArgumentError, "unsupported write operation: #{operation}"
        end
      end

      # Full pre-update attributes: the current values with the changed columns
      # reverted to their saved-change "before" values.
      sig { params(record: ::ActiveRecord::Base).returns(Attributes) }
      def self.old_attributes(record)
        attributes = stringify_keys(record.attributes)
        record.saved_changes.each_pair { |column, (old_value, _new_value)| attributes[column.to_s] = old_value }
        attributes
      end

      sig { params(values: T::Hash[T.any(String, Symbol), T.untyped]).returns(Attributes) }
      def self.stringify_keys(values)
        values.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
      end

      private_class_method :old_attributes, :stringify_keys
    end
  end
end
