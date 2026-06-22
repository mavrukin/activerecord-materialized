# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Applies an accumulated SummaryDelta to a delta-maintainable view's cache
    # table without re-reading base rows: new partitions are inserted, existing
    # ones incremented in place (NULL-safe for SUM), and partitions whose row
    # count reaches zero are deleted so the cache matches the raw GROUP BY.
    class DeltaMaintainer
      extend T::Sig

      sig { params(view_class: ViewClass).void }
      def initialize(view_class)
        @view_class = view_class
        @analysis = T.let(AggregateAnalysis.new(view_class.resolved_source), AggregateAnalysis)
      end

      sig { params(summary: SummaryDelta).returns(Integer) }
      def apply!(summary)
        summary.buckets.each { |key_tuple, column_deltas| apply_partition(key_tuple, column_deltas) }
        T.unsafe(@view_class).unscoped.count
      end

      private

      sig { returns(T::Array[String]) }
      def group_columns
        @view_class.maintenance_key_columns
      end

      sig { params(key_tuple: SummaryDelta::KeyTuple, column_deltas: T::Hash[String, Numeric]).void }
      def apply_partition(key_tuple, column_deltas)
        existing = partition_scope(key_tuple).first
        if existing.nil?
          insert_partition(key_tuple, column_deltas)
        elsif emptied?(existing, column_deltas)
          existing.destroy!
        else
          add_deltas!(existing, column_deltas)
        end
      end

      sig { params(key_tuple: SummaryDelta::KeyTuple).returns(::ActiveRecord::Relation) }
      def partition_scope(key_tuple)
        T.unsafe(@view_class).unscoped.where(group_columns.zip(key_tuple).to_h)
      end

      sig { params(key_tuple: SummaryDelta::KeyTuple, column_deltas: T::Hash[String, Numeric]).void }
      def insert_partition(key_tuple, column_deltas)
        # A new partition started empty, so the accumulated deltas are its
        # absolute aggregate values. Aggregates with no (or a pruned-zero) delta
        # default to 0 rather than NULL — the partition has rows, and a
        # distributive aggregate over them is numeric (e.g. SUM of a single 0).
        defaults = @analysis.aggregate_columns.to_h { |column| [column.name, 0] }
        row = group_columns.zip(key_tuple).to_h.merge(defaults).merge(column_deltas)
        T.unsafe(@view_class).create!(row)
      end

      # Adds each delta to the partition's current value, treating a NULL SUM (a
      # partition whose values were all nil) as zero for the first contribution.
      sig { params(existing: T.untyped, column_deltas: T::Hash[String, Numeric]).void }
      def add_deltas!(existing, column_deltas)
        new_values = column_deltas.to_h { |column, amount| [column, (existing[column] || 0) + amount] }
        existing.update!(new_values)
      end

      sig { params(existing: T.untyped, column_deltas: T::Hash[String, Numeric]).returns(T::Boolean) }
      def emptied?(existing, column_deltas)
        column = @analysis.row_count_column
        return false if column.nil?

        delta = column_deltas[column.name] || 0
        (existing[column.name].to_i + delta) <= 0
      end
    end
  end
end
