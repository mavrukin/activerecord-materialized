# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Tracks which partitions of a *cold* view have been materialized into the
    # cache table ("fresh"). Warm views are fully materialized and ignore this;
    # cold views are partially materialized, so a read consults the fresh set to
    # decide whether a partition is served from the cache or read through to the
    # source.
    class PartitionState
      extend T::Sig

      KeyTuple = T.type_alias { T::Array[T.untyped] }

      sig { params(view_class: ViewClass).void }
      def initialize(view_class)
        @view_class = view_class
      end

      sig { params(key_tuples: T::Array[KeyTuple]).returns(T::Boolean) }
      def all_fresh?(key_tuples)
        return false if key_tuples.empty?

        ensure_table!
        serialized = key_tuples.map { |tuple| serialize(tuple) }.uniq
        scope.where(partition_key: serialized).count == serialized.size
      end

      sig { params(key_tuples: T::Array[KeyTuple]).void }
      def mark_fresh!(key_tuples)
        return if key_tuples.empty?

        ensure_table!
        key_tuples.uniq.each do |tuple|
          PartitionRecord.create_or_find_by(view_name: view_key, partition_key: serialize(tuple))
        end
      end

      sig { params(key_tuples: T::Array[KeyTuple]).void }
      def mark_stale!(key_tuples)
        return if key_tuples.empty?

        ensure_table!
        scope.where(partition_key: key_tuples.map { |tuple| serialize(tuple) }).delete_all
      end

      sig { void }
      def reset!
        ensure_table!
        scope.delete_all
      end

      # Extracts the partition key tuples a query touches, or nil when the scope
      # cannot be determined (no group-key filter, extra columns, raw SQL, …).
      # Only an exact match on the GROUP BY columns qualifies for the per-
      # partition fast path.
      sig { params(view_class: ViewClass, args: T::Array[T.untyped]).returns(T.nilable(T::Array[KeyTuple])) }
      def self.keys_from(view_class, args)
        conditions = single_hash(args)
        return nil if conditions.nil?

        group_keys = view_class.maintenance_key_columns
        return nil if group_keys.empty?

        value_lists = key_value_lists(conditions, group_keys)
        value_lists.nil? ? nil : cartesian(value_lists)
      end

      sig { params(args: T::Array[T.untyped]).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
      def self.single_hash(args)
        return nil unless args.length == 1

        conditions = args.fetch(0)
        conditions.is_a?(Hash) ? conditions : nil
      end

      # The value lists for each GROUP BY column, or nil unless the conditions
      # name exactly the GROUP BY columns (an exact partition lookup).
      sig do
        params(conditions: T::Hash[T.untyped, T.untyped], group_keys: T::Array[String])
          .returns(T.nilable(T::Array[T::Array[String]]))
      end
      def self.key_value_lists(conditions, group_keys)
        normalized = conditions.transform_keys(&:to_s)
        return nil unless normalized.keys.sort == group_keys.sort

        group_keys.map { |column| Array(normalized.fetch(column)).map(&:to_s) }
      end

      sig { params(value_lists: T::Array[T::Array[String]]).returns(T.nilable(T::Array[KeyTuple])) }
      def self.cartesian(value_lists)
        return nil if value_lists.any?(&:empty?)

        value_lists.reduce([[]]) do |tuples, values|
          tuples.flat_map { |tuple| values.map { |value| tuple + [value] } }
        end
      end

      private

      sig { returns(String) }
      def view_key
        @view_class.view_key
      end

      sig { params(key_tuple: KeyTuple).returns(String) }
      def serialize(key_tuple)
        key_tuple.map(&:to_s).to_json
      end

      sig { returns(::ActiveRecord::Relation) }
      def scope
        PartitionRecord.where(view_name: view_key)
      end

      sig { void }
      def ensure_table!
        connection = @view_class.connection
        return if PartitionRecord.table_exists?

        table = ::ActiveRecord::Materialized.partition_table_name
        connection.create_table(table) do |t|
          t.string :view_name, null: false
          t.string :partition_key, null: false
          t.datetime :created_at, null: false
        end
        connection.add_index(table, %i[view_name partition_key], unique: true)
        PartitionRecord.reset_column_information
      end
    end
  end
end
