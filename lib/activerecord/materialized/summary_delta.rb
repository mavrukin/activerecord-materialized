# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Accumulates signed per-partition, per-column numeric changes for a
    # delta-maintainable view (`partition key tuple => mv column => amount`).
    #
    # @api private
    class SummaryDelta
      attr_reader :buckets

      def initialize(buckets = {})
        @buckets = buckets
      end

      def add(key_tuple, column, amount)
        bucket = (@buckets[key_tuple] ||= {})
        bucket[column] = (bucket[column] || 0) + amount
      end

      def empty?
        @buckets.empty?
      end

      # Number of distinct partitions (buckets) accumulated so far.
      def tracked_partition_count
        @buckets.size
      end

      # Drops net-zero columns (no-op changes) and the partitions left empty.
      def prune!
        @buckets.each_value { |columns| columns.reject! { |_column, amount| amount.zero? } }
        @buckets.reject! { |_key_tuple, columns| columns.empty? }
        self
      end

      def merge(other)
        merged = SummaryDelta.new(@buckets.transform_values(&:dup))
        other.buckets.each do |key_tuple, columns|
          columns.each { |column, amount| merged.add(key_tuple, column, amount) }
        end
        merged
      end

      # A list of `"key" => tuple, "columns" => …` entries so array keys survive JSON.
      def serialize
        { "summary" => @buckets.map { |key_tuple, columns| { "key" => key_tuple, "columns" => columns } } }
      end

      def self.deserialize(payload)
        rows = payload && payload["summary"]
        return nil if rows.nil?

        buckets = {}
        rows.each { |row| buckets[row.fetch("key")] = row.fetch("columns") }
        new(buckets)
      end
    end
  end
end
