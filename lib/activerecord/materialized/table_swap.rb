# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Swaps a view's cache table for a freshly-built temp table, atomically per the
    # engine's DDL semantics: a transaction on SQLite/Postgres (transactional DDL),
    # or a single multi-table RENAME TABLE on MySQL — whose DDL auto-commits, so a
    # transaction could not make two separate renames atomic. Extracted from
    # RelationCacheWriter, which builds the temp table and delegates the swap here.
    #
    # @api private
    class TableSwap
      def initialize(view_class)
        @view_class = view_class
      end

      # Replace the view table with temp_table; the displaced view table becomes
      # old_table and is dropped. Indexes on the displaced table are preserved: the freshly built
      # temp table only carries the schema-default index, so any index a user added to the cache table
      # (or the default one, on a table built before it existed) would otherwise be lost with the
      # dropped old table — unlike PostgreSQL's REFRESH MATERIALIZED VIEW, which keeps them.
      def swap!(temp_table, old_table)
        preserved = current_indexes
        if connection.supports_ddl_transactions?
          connection.transaction do
            rename_in_place!(temp_table, old_table)
            restore_missing_indexes!(preserved)
          end
        else
          atomic_rename!(temp_table, old_table)
          restore_missing_indexes!(preserved)
        end
      end

      private

      attr_reader :view_class

      def connection = view_class.connection

      # The indexes on the current live cache table (empty on first build, when there is none), captured
      # before the swap so they can be re-created on the table that replaces it.
      def current_indexes
        return [] unless view_class.table_exists?

        connection.indexes(view_class.table_name)
      end

      # Re-create every preserved index the swapped-in table does not already carry (matched on full
      # signature, so the temp table's default index isn't duplicated). Index names are free again now
      # that the old table is dropped, so each keeps its original name.
      def restore_missing_indexes!(preserved)
        existing = connection.indexes(view_class.table_name)
        preserved.each do |index|
          next if existing.any? { |candidate| same_index?(candidate, index) }

          connection.add_index(view_class.table_name, index.columns, **index_options(index))
        end
      end

      def same_index?(one, other)
        one.columns == other.columns && one.unique == other.unique && one.where == other.where &&
          one.orders == other.orders && one.using == other.using
      end

      def index_options(index)
        options = { name: index.name, unique: index.unique }
        options[:where] = index.where if index.where
        options[:using] = index.using if index.using
        options[:order] = index.orders if index.orders.present?
        options
      end

      def rename_in_place!(temp_table, old_table)
        connection.rename_table(view_class.table_name, old_table) if view_class.table_exists?
        connection.rename_table(temp_table, view_class.table_name)
        connection.drop_table(old_table, if_exists: true)
      end

      # MySQL: `RENAME TABLE current TO old, temp TO current` swaps in one atomic
      # statement (a single metadata lock over all tables), then the old table is
      # dropped. On first build there is no current table, so just rename temp in.
      def atomic_rename!(temp_table, old_table)
        view = view_class.table_name
        unless view_class.table_exists?
          connection.rename_table(temp_table, view)
          return
        end

        connection.execute(rename_sql(view => old_table, temp_table => view))
        connection.drop_table(old_table, if_exists: true)
      end

      def rename_sql(pairs)
        clauses = pairs.map { |from, to| "#{connection.quote_table_name(from)} TO #{connection.quote_table_name(to)}" }
        "RENAME TABLE #{clauses.join(', ')}"
      end
    end
  end
end
