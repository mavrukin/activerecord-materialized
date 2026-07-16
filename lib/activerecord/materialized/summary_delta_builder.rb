# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # The SummaryDelta a single write contributes. Subtracting the "before"
    # snapshot and adding the "after" uniformly handles inserts, deletes, in-place
    # updates, and group-key changes (a move between partitions).
    class SummaryDeltaBuilder
      def initialize(change, analysis, group_columns)
        @change = change
        @analysis = analysis
        @group_columns = group_columns
      end

      def build
        delta = SummaryDelta.new
        apply!(delta, @change.before, -1) unless @change.before.empty?
        apply!(delta, @change.after, 1) unless @change.after.empty?
        delta.prune!
      end

      private

      def apply!(delta, snapshot, sign)
        key_tuple = key_tuple(snapshot)
        return if key_tuple.nil?

        @analysis.aggregate_columns.each do |column|
          contribution = contribution_for(column, snapshot)
          delta.add(key_tuple, column.name, sign * contribution) unless contribution.zero?
        end
      end

      def contribution_for(column, snapshot)
        case column.function
        when :count_star then 1
        when :count then snapshot[column.attribute].nil? ? 0 : 1
        when :sum then snapshot.fetch(column.attribute, 0) || 0
        else 0
        end
      end

      def key_tuple(snapshot)
        return nil unless @group_columns.all? { |column| snapshot.key?(column) }

        @group_columns.map { |column| snapshot.fetch(column) }
      end
    end
  end
end
