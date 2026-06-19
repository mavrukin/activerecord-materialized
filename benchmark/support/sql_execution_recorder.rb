# frozen_string_literal: true

module BenchmarkSupport
  class SqlExecutionRecorder
    RENAME_PATTERN = /ALTER TABLE .* RENAME TO/i
    BOOTSTRAP_REFRESH_PATTERN = /CREATE TABLE .*?_refresh_/i
    MAINTENANCE_WRITE_PATTERN = /(?:DELETE FROM|INSERT INTO) /i

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
      @statements.any? { |statement| statement.match?(MAINTENANCE_WRITE_PATTERN) } &&
        !bootstrap_swap_detected?
    end

    def install!(connection)
      recorder = self
      connection.singleton_class.prepend(Module.new do
        define_method(:execute) do |sql, *args, **kwargs, &block|
          recorder.record(sql)
          super(sql, *args, **kwargs, &block)
        end

        define_method(:rename_table) do |table_name, new_name, **kwargs|
          recorder.record("ALTER TABLE #{table_name} RENAME TO #{new_name}")
          super(table_name, new_name, **kwargs)
        end

        define_method(:create_table) do |table_name, **kwargs, &block|
          recorder.record("CREATE TABLE #{table_name}")
          super(table_name, **kwargs, &block)
        end
      end)
      self
    end
  end
end
