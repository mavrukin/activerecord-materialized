# frozen_string_literal: true

module ActiveRecord
  module Materialized
  class DependencyRegistry
    class << self
      def register(view_class, tables)
        tables = Array(tables).map { |table| normalize_table(table) }
        view_class.instance_variable_set(:@dependency_tables, tables)

        tables.each do |table|
          dependency_index[table] << view_class unless dependency_index[table].include?(view_class)
        end
      end

      def views_for_table(table)
        dependency_index[normalize_table(table)]
      end

      def schedule_refresh_for_tables!(tables)
        affected_views(tables).each { |view| RefreshScheduler.schedule(view) }
      end

      def mark_dirty_for_tables!(tables)
        affected_views(tables).each(&:mark_dependencies_changed!)
      end

      def reset!
        @dependency_index = Hash.new { |hash, key| hash[key] = [] }
        @recorders = {}
      end

      def recorder_for(connection)
        recorders[connection.object_id] ||= TransactionRefreshRecorder.new(connection)
      end

      def clear_recorder(connection)
        recorders.delete(connection.object_id)
      end

      private

      def recorders
        @recorders ||= {}
      end

      def dependency_index
        @dependency_index ||= Hash.new { |hash, key| hash[key] = [] }
      end

      def affected_views(tables)
        Array(tables).flat_map do |table|
          next [] if skip_table?(table)

          views_for_table(table)
        end.uniq
      end

      def normalize_table(table)
        table.to_s.delete_prefix(":").underscore
      end

      def skip_table?(table)
        name = normalize_table(table)
        name.start_with?("mv_") || name == ActiveRecord::Materialized.metadata_table_name
      end
    end
  end
  end
end
