# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # The SummaryDelta a single write contributes. Subtracting the "before"
    # snapshot and adding the "after" uniformly handles inserts, deletes, in-place
    # updates, and group-key changes (a move between partitions).
    class SummaryDeltaBuilder
      extend T::Sig

      sig { params(change: WriteChange, analysis: AggregateAnalysis, group_columns: T::Array[String]).void }
      def initialize(change, analysis, group_columns)
        @change = change
        @analysis = analysis
        @group_columns = group_columns
      end

      sig { returns(SummaryDelta) }
      def build
        delta = SummaryDelta.new
        apply!(delta, @change.before, -1) unless @change.before.empty?
        apply!(delta, @change.after, 1) unless @change.after.empty?
        delta.prune!
      end

      private

      sig { params(delta: SummaryDelta, snapshot: T::Hash[String, T.untyped], sign: Integer).void }
      def apply!(delta, snapshot, sign)
        key_tuple = key_tuple(snapshot)
        return if key_tuple.nil?

        @analysis.aggregate_columns.each do |column|
          contribution = contribution_for(column, snapshot)
          delta.add(key_tuple, column.name, sign * contribution) unless contribution.zero?
        end
      end

      sig { params(column: AggregateAnalysis::Column, snapshot: T::Hash[String, T.untyped]).returns(Numeric) }
      def contribution_for(column, snapshot)
        case column.function
        when :count_star then 1
        when :count then snapshot[T.must(column.attribute)].nil? ? 0 : 1
        when :sum then snapshot.fetch(T.must(column.attribute), 0) || 0
        else 0
        end
      end

      sig { params(snapshot: T::Hash[String, T.untyped]).returns(T.nilable(SummaryDelta::KeyTuple)) }
      def key_tuple(snapshot)
        return nil unless @group_columns.all? { |column| snapshot.key?(column) }

        @group_columns.map { |column| snapshot.fetch(column) }
      end
    end
  end
end
