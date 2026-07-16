# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"

module ActiverecordMaterialized
  # `rails generate activerecord_materialized:install` — installs the metadata-table migration.
  class InstallGenerator < ::Rails::Generators::Base
    include Rails::Generators::Migration

    source_root File.expand_path("install", __dir__)

    def self.next_migration_number(dirname)
      next_migration_number = current_migration_number(dirname) + 1
      ::ActiveRecord::Migration.next_migration_number(next_migration_number)
    end

    def copy_migration
      migration_template "create_ar_materialized_view_metadata.rb.erb",
                         "db/migrate/create_ar_materialized_view_metadata.rb"
    end

    def show_readme
      readme "README" if behavior == :invoke
    end
  end
end
