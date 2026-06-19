# frozen_string_literal: true

module BenchmarkSupport
  class SqlExecutionRecorder
    RENAME_PATTERN = /ALTER TABLE .* RENAME TO/i
    BOOTSTRAP_REFRESH_PATTERN = /CREATE TABLE (?!TEMP\b).*?_refresh_/i
    INCREMENTAL_TEMP_PATTERN = /CREATE TEMP TABLE .*?_maint_/i

    def initialize
      @statements = []
    end

    attr_reader :statements

    def record(sql)
      @statements << sql.to_s
    end

    def bootstrap_swap_detected?
      @statements.any? do |statement|
        statement.match?(BOOTSTRAP_REFRESH_PATTERN) || statement.match?(RENAME_PATTERN)
      end
    end

    def incremental_maintenance_detected?
      @statements.any? { |statement| statement.match?(INCREMENTAL_TEMP_PATTERN) }
    end

    def install!(connection)
      recorder = self
      connection.singleton_class.prepend(Module.new do
        define_method(:execute) do |sql, *args, **kwargs, &block|
          recorder.record(sql)
          super(sql, *args, **kwargs, &block)
        end
      end)
      self
    end
  end
end
