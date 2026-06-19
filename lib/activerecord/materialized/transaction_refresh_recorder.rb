# frozen_string_literal: true

module ActiveRecord
  module Materialized
  class TransactionRefreshRecorder
    def initialize(connection)
      @connection = connection
      @tables = []
      @callbacks_registered = false
    end

    def add_tables(tables)
      @tables.concat(Array(tables))
      register_callbacks! unless @callbacks_registered
    end

    private

    def register_callbacks!
      transaction = @connection.current_transaction
      return unless transaction

      transaction.after_commit do
        DependencyRegistry.schedule_refresh_for_tables!(@tables) if @tables.any?
      ensure
        DependencyRegistry.clear_recorder(@connection)
      end

      transaction.after_rollback do
        @tables.clear
      ensure
        DependencyRegistry.clear_recorder(@connection)
      end

      @callbacks_registered = true
    end
  end
  end
end
