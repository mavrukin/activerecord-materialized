# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Builds the source of a Rails migration that provisions a view's (empty)
    # cache table, with columns/types inferred from the view's source relation.
    # This is what lets an MV table be created by `db:migrate` rather than at
    # runtime.
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

      sig { returns(T::Array[CacheTableSchema::ColumnDefinition]) }
      def column_definitions
        CacheTableSchema.column_definitions(@view_class.connection, @view_class.resolved_source)
      end

      sig { params(migration_version: T.any(String, Float)).returns(String) }
      def migration_source(migration_version: ::ActiveRecord::Migration.current_version)
        <<~RUBY
          # frozen_string_literal: true

          class #{migration_class_name} < ActiveRecord::Migration[#{migration_version}]
            def change
              create_table :#{table_name} do |t|
          #{column_lines}
              end
            end
          end
        RUBY
      end

      private

      sig { returns(String) }
      def column_lines
        column_definitions.map { |definition| "      t.#{definition.type} :#{definition.name}" }.join("\n")
      end
    end
  end
end
