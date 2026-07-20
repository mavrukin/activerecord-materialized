# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"

module ActiverecordMaterialized
  # Generates a migration that installs write-outbox triggers on a dependency table, so writes that
  # bypass ActiveRecord (raw SQL, another service, a backfill) are still captured and can be relayed
  # into view maintenance via +ActiveRecord::Materialized.drain_write_outbox!+:
  #
  #   bin/rails generate activerecord_materialized:outbox line_items category region
  #
  # The trailing arguments are the GROUP BY key columns to capture (empty for an un-grouped view).
  # The migration emits the correct trigger DDL for the connection's adapter at migrate time.
  # See +docs/out-of-band-writes.md+.
  class OutboxGenerator < ::Rails::Generators::NamedBase
    include ::Rails::Generators::Migration

    source_root File.expand_path("templates", __dir__)

    argument :columns, type: :array, default: [],
                       banner: "key_column key_column",
                       desc: "GROUP BY key columns to capture (the partition keys)"

    def self.next_migration_number(dirname)
      ::ActiveRecord::Migration.next_migration_number(current_migration_number(dirname) + 1)
    end

    def create_migration_file
      # +file_name+, not NamedBase#table_name: NAME is a raw dependency table, and table_name would
      # inflect it (pluralize a singular/irregular table — person -> people), targeting the wrong table.
      migration_template "write_outbox_migration.rb.erb",
                         File.join("db", "migrate", "install_write_outbox_triggers_on_#{file_name}.rb")
    end
  end
end
