# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # The data a generated migration needs to provision a view's empty cache
    # table: table name, migration class name, target version, and inferred
    # columns/types. The file itself is produced by Rails' generator tooling.
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
