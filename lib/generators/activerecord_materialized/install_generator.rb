# typed: strict
# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"

module ActiverecordMaterialized
  # `rails generate activerecord_materialized:install` — installs the metadata-table migration.
  class InstallGenerator < ::Rails::Generators::Base
    extend T::Sig
    include Rails::Generators::Migration

    source_root File.expand_path("install", __dir__)

    sig { params(dirname: String).returns(String) }
    def self.next_migration_number(dirname)
      next_migration_number = T.unsafe(self).current_migration_number(dirname) + 1
      ::ActiveRecord::Migration.next_migration_number(next_migration_number)
    end

    sig { void }
    def copy_migration
      migration_template "create_ar_materialized_view_metadata.rb.erb",
                         "db/migrate/create_ar_materialized_view_metadata.rb"
    end

    sig { void }
    def show_readme
      readme "README" if behavior == :invoke
    end
  end
end
