# typed: strict
# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"

module ActiverecordMaterialized
  # Generates a migration that provisions a materialized view's (empty) cache
  # table, with columns inferred from the view's source relation:
  #
  #   bin/rails generate activerecord_materialized:migration SalesSummary
  #
  # Run after the view's `materialized_from` is defined, then `db:migrate`.
  class MigrationGenerator < ::Rails::Generators::NamedBase
    extend T::Sig
    include ::Rails::Generators::Migration

    source_root File.expand_path("templates", __dir__)

    sig { params(dirname: String).returns(String) }
    def self.next_migration_number(dirname)
      ::ActiveRecord::Migration.next_migration_number(T.unsafe(self).current_migration_number(dirname) + 1)
    end

    sig { void }
    def create_migration_file
      migration_template "materialized_view_migration.rb.erb",
                         File.join("db", "migrate", "create_#{builder.table_name}.rb")
    end

    private

    sig { returns(::ActiveRecord::Materialized::MigrationBuilder) }
    def builder
      @builder ||= T.let(build_builder, T.nilable(::ActiveRecord::Materialized::MigrationBuilder))
    end

    # Resolve via the registry (after eager-load) rather than constantize.
    sig { returns(::ActiveRecord::Materialized::MigrationBuilder) }
    def build_builder
      T.unsafe(::Rails).application.eager_load!
      view_class = ::ActiveRecord::Materialized::Registry.for_class_name(class_name)
      if view_class.nil?
        Kernel.raise ::Thor::Error,
                     "Unknown materialized view: #{class_name}. Define it before generating its migration."
      end

      ::ActiveRecord::Materialized::MigrationBuilder.new(view_class)
    end
  end
end
