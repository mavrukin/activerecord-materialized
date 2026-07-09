# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Derives the affected partition keys for a write from its ActiveRecord change payload.
    #
    # @api private
    class MaintenanceDeltaBuilder
      extend T::Sig

      sig do
        params(
          change: WriteChange,
          key_columns: T::Array[String],
          resolver: T.nilable(ViewIncrementalClassMethods::PartitionKeyResolver)
        ).void
      end
      def initialize(change, key_columns, resolver: nil)
        @change = change
        @key_columns = key_columns
        @resolver = resolver
      end

      sig { returns(MaintenanceDelta) }
      def build
        return MaintenanceDelta.full_partition if @key_columns.empty?

        # A resolver is an explicit per-table mapping, so it is authoritative for
        # that table's writes (it maps to the group key wherever it lives, even if
        # the written row happens to carry a same-named column); otherwise the key
        # comes from the written row's own payload.
        tuples = @resolver ? resolved_tuples : extract_tuples
        tuples.empty? ? MaintenanceDelta.full_partition : MaintenanceDelta.scoped(tuples.uniq)
      end

      private

      sig { returns(T::Array[T::Array[T.untyped]]) }
      def extract_tuples
        snapshots = case @change.operation.to_sym
                    when :create then [@change.after]
                    when :destroy then [@change.before]
                    when :update then [@change.before, @change.after]
                    else []
                    end
        snapshots.filter_map { |attributes| key_tuple(attributes) }.uniq
      end

      # Partition key tuple(s) from the configured resolver, or [] (=> full
      # recompute) when none is set or it yields nothing.
      sig { returns(T::Array[T::Array[T.untyped]]) }
      def resolved_tuples
        resolver = @resolver
        return [] if resolver.nil?

        normalize_keys(resolver.call(@change))
      end

      # Coerces a resolver's return into partition-key tuples, using the group key's
      # arity to tell a single composite tuple from a list of tuples. A nil/empty
      # return widens (=> full recompute); a returned nil value is a real key (the
      # NULL partition), so it is kept rather than dropped.
      sig { params(result: T.untyped).returns(T::Array[T::Array[T.untyped]]) }
      def normalize_keys(result)
        return [] if result.nil?

        @key_columns.one? ? Array(result).zip : composite_tuples(result)
      end

      # A composite key expects a tuple or an array of tuples; anything else (a bare
      # scalar, nil, empty) can't be scoped, so it widens rather than crashing.
      sig { params(result: T.untyped).returns(T::Array[T::Array[T.untyped]]) }
      def composite_tuples(result)
        return [] unless result.is_a?(Array) && result.any?

        result.first.is_a?(Array) ? result : [result]
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
        # Look up by presence so falsey group-key values map to their partition.
        return attributes[column] if attributes.key?(column)

        T.unsafe(attributes)[column.to_sym]
      end
    end
  end
end
