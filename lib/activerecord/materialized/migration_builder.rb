# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # The data a generated migration needs to provision a view's empty cache
    # table: table name, migration class name, target version, and inferred
    # columns/types. The file itself is produced by Rails' generator tooling.
    class MigrationBuilder
      def initialize(view_class)
        @view_class = view_class
      end

      def table_name
        @view_class.table_name
      end

      def migration_class_name
        "Create#{table_name.camelize}"
      end

      def migration_version
        ::ActiveRecord::Migration.current_version
      end

      def column_definitions
        CacheTableSchema.column_definitions(@view_class.connection, @view_class.resolved_source)
      end

      # The partition-key index the migration should add (nil for a non-grouped view). Incremental
      # maintenance is keyed on these columns, so the generated migration indexes them by default.
      #
      # @return [CacheTableSchema::IndexDefinition, nil]
      def index_definition
        CacheTableSchema.index_definition(@view_class)
      end
    end
  end
end
