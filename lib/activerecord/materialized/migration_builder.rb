# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Supplies the data a generated migration needs to provision a view's
    # (empty) cache table: the table name, migration class name, target Rails
    # migration version, and the columns/types inferred from the source
    # relation. The migration file itself is produced by Rails' generator
    # tooling (migration_template + the ERB template), not by string building.
    class MigrationBuilder
      extend T::Sig

      sig { params(view_class: ViewClass).void }
      def initialize(view_class)
        @view_class = view_class
      end

      sig { returns(String) }
      def table_name
        @view_class.table_name
      end

      sig { returns(String) }
      def migration_class_name
        "Create#{table_name.camelize}"
      end

      sig { returns(T.any(String, Float)) }
      def migration_version
        ::ActiveRecord::Migration.current_version
      end

      sig { returns(T::Array[CacheTableSchema::ColumnDefinition]) }
      def column_definitions
        CacheTableSchema.column_definitions(@view_class.connection, @view_class.resolved_source)
      end
    end
  end
end
