# frozen_string_literal: true

module ActiveRecord
  module Materialized
  class ChangeSubscriber
    WRITE_SQL = /\A\s*(INSERT|UPDATE|DELETE|REPLACE)\b/i.freeze
    TABLE_PATTERN = /
      (?:INSERT\s+INTO|UPDATE|DELETE\s+FROM|REPLACE\s+INTO)\s+
      (?:
        (?:`([^`]+)`|"([^"]+)"|(\w+))
      )
    /ix.freeze

    class << self
      def install!
        return if installed?

        @subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
          handle_sql_event(ActiveSupport::Notifications::Event.new(*args))
        end
        @installed = true
      end

      def uninstall!
        ActiveSupport::Notifications.unsubscribe(@subscription) if @subscription
        @subscription = nil
        @installed = false
      end

      def installed?
        @installed == true
      end

      def extract_tables(sql)
        sql.to_s.scan(TABLE_PATTERN).flat_map(&:compact).uniq
      end

      private

      def handle_sql_event(event)
        payload = event.payload
        return if payload[:cached]
        return if payload[:name] == "SCHEMA"
        return if refreshing_query?(payload[:sql])

        sql = payload[:sql].to_s
        return unless sql.match?(WRITE_SQL)

        tables = extract_tables(sql)
        return if tables.empty?

        connection = payload[:connection] || ActiveRecord::Base.connection
        if connection.transaction_open?
          DependencyRegistry.recorder_for(connection).add_tables(tables)
        else
          DependencyRegistry.schedule_refresh_for_tables!(tables)
        end
      end

      def refreshing_query?(sql)
        sql.to_s.match?(/CREATE TABLE .*_refresh_/i) ||
          sql.to_s.include?(ActiveRecord::Materialized.metadata_table_name)
      end
    end
  end
  end
end
