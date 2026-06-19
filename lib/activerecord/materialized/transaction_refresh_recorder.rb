# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class TransactionRefreshRecorder
      extend T::Sig

      sig { void }
      def initialize
        @tables = T.let([], T::Array[String])
        @sql_statements = T.let([], T::Array[String])
        @callbacks_registered = T.let(false, T::Boolean)
        @connection = T.let(nil, T.nilable(Connection))
      end

      sig { params(connection: Connection).void }
      def bind_connection!(connection)
        @connection = connection
      end

      sig { params(tables: T::Array[String], sql: T.nilable(String)).void }
      def add_tables(tables, sql: nil)
        @tables.concat(tables)
        @sql_statements << sql if sql
        register_callbacks! unless @callbacks_registered
      end

      private

      sig { void }
      def register_callbacks!
        connection = T.must(@connection)
        transaction = connection.current_transaction
        return unless transaction

        transaction.after_commit do
          DependencyRegistry.schedule_refresh_for_tables!(@tables, sql_statements: @sql_statements) if @tables.any?
        ensure
          DependencyRegistry.clear_recorder(connection)
        end

        transaction.after_rollback do
          @tables.clear
          @sql_statements.clear
        ensure
          DependencyRegistry.clear_recorder(connection)
        end

        @callbacks_registered = true
      end
    end
  end
end
