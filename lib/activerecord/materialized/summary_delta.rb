# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Accumulates signed per-partition, per-column numeric changes for a
    # delta-maintainable view (`partition key tuple => mv column => amount`).
    #
    # @api private
    class SummaryDelta
      extend T::Sig

      KeyTuple = T.type_alias { T::Array[T.untyped] }
      Columns = T.type_alias { T::Hash[String, Numeric] }
      Buckets = T.type_alias { T::Hash[KeyTuple, Columns] }

      sig { returns(Buckets) }
      attr_reader :buckets

      sig { params(buckets: Buckets).void }
      def initialize(buckets = {})
        @buckets = buckets
      end

      sig { params(key_tuple: KeyTuple, column: String, amount: Numeric).void }
      def add(key_tuple, column, amount)
        bucket = (@buckets[key_tuple] ||= {})
        bucket[column] = (bucket[column] || 0) + amount
      end

      sig { returns(T::Boolean) }
      def empty?
        @buckets.empty?
      end

      # Drops net-zero columns (no-op changes) and the partitions left empty.
      sig { returns(SummaryDelta) }
      def prune!
        @buckets.each_value { |columns| columns.reject! { |_column, amount| amount.zero? } }
        @buckets.reject! { |_key_tuple, columns| columns.empty? }
        self
      end

      sig { params(other: SummaryDelta).returns(SummaryDelta) }
      def merge(other)
        merged = SummaryDelta.new(@buckets.transform_values(&:dup))
        other.buckets.each do |key_tuple, columns|
          columns.each { |column, amount| merged.add(key_tuple, column, amount) }
        end
        merged
      end

      # A list of `"key" => tuple, "columns" => …` entries so array keys survive JSON.
      sig { returns(T::Hash[String, T.untyped]) }
      def serialize
        { "summary" => @buckets.map { |key_tuple, columns| { "key" => key_tuple, "columns" => columns } } }
      end

      sig { params(payload: T.nilable(T::Hash[String, T.untyped])).returns(T.nilable(SummaryDelta)) }
      def self.deserialize(payload)
        rows = payload && payload["summary"]
        return nil if rows.nil?

        buckets = T.let({}, Buckets)
        rows.each { |row| buckets[row.fetch("key")] = row.fetch("columns") }
        new(buckets)
      end
    end
  end
end
