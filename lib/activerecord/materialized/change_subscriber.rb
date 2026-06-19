# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class ChangeSubscriber
      WRITE_SQL = T.let(/\A\s*(INSERT|UPDATE|DELETE|REPLACE)\b/i, Regexp)
      TABLE_PATTERN = T.let(
        /
          (?:INSERT\s+INTO|UPDATE|DELETE\s+FROM|REPLACE\s+INTO)\s+
          (?:
            (?:`([^`]+)`|"([^"]+)"|(\w+))
          )
        /ix,
        Regexp
      )

      class << self
        extend T::Sig

        sig { void }
        def install!
          return if installed?

          @subscription = T.let(
            ::ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
              handle_sql_event(::ActiveSupport::Notifications::Event.new(*args))
            end,
            T.nilable(Object)
          )
          @installed = T.let(true, T.nilable(T::Boolean))
        end

        sig { void }
        def uninstall!
          ::ActiveSupport::Notifications.unsubscribe(@subscription) if @subscription
          @subscription = T.let(nil, T.nilable(Object))
          @installed = T.let(false, T.nilable(T::Boolean))
        end

        sig { returns(T::Boolean) }
        def installed?
          @installed == true
        end

        sig { params(sql: T.any(String, Symbol)).returns(T::Array[String]) }
        def extract_tables(sql)
          T.cast(sql.to_s.scan(TABLE_PATTERN), T::Array[T::Array[T.nilable(String)]])
           .flat_map(&:compact)
           .uniq
        end

        private

        sig { params(event: ::ActiveSupport::Notifications::Event).void }
        def handle_sql_event(event)
          payload = event.payload
          return if payload[:cached]
          return if payload[:name] == "SCHEMA"
          return if refreshing_query?(T.cast(payload[:sql], T.nilable(String)))

          sql = payload[:sql].to_s
          return unless sql.match?(WRITE_SQL)

          tables = extract_tables(sql)
          return if tables.empty?

          connection = resolve_connection(payload)
          if connection.transaction_open?
            DependencyRegistry.recorder_for(connection).add_tables(tables)
          else
            DependencyRegistry.schedule_refresh_for_tables!(tables)
          end
        end

        sig { params(payload: T::Hash[Symbol, T.untyped]).returns(Connection) }
        def resolve_connection(payload)
          raw = payload[:connection]
          connection = raw.nil? ? ::ActiveRecord::Base.connection : raw
          T.cast(connection, Connection)
        end

        sig { params(sql: T.nilable(String)).returns(T::Boolean) }
        def refreshing_query?(sql)
          sql.to_s.match?(/CREATE TABLE .*_refresh_/i) ||
            sql.to_s.include?(::ActiveRecord::Materialized.metadata_table_name)
        end
      end
    end
  end
end
