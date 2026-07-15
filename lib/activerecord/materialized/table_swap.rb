# typed: strict
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
      extend T::Sig

      sig { params(view_class: T.class_of(::ActiveRecord::Base)).void }
      def initialize(view_class)
        @view_class = view_class
      end

      # Replace the view table with temp_table; the displaced view table becomes
      # old_table and is dropped.
      sig { params(temp_table: String, old_table: String).void }
      def swap!(temp_table, old_table)
        if T.unsafe(connection).supports_ddl_transactions?
          connection.transaction { rename_in_place!(temp_table, old_table) }
        else
          atomic_rename!(temp_table, old_table)
        end
      end

      private

      sig { returns(T.class_of(::ActiveRecord::Base)) }
      attr_reader :view_class

      sig { returns(Connection) }
      def connection = view_class.connection

      sig { params(temp_table: String, old_table: String).void }
      def rename_in_place!(temp_table, old_table)
        connection.rename_table(view_class.table_name, old_table) if view_class.table_exists?
        connection.rename_table(temp_table, view_class.table_name)
        connection.drop_table(old_table, if_exists: true)
      end

      # MySQL: `RENAME TABLE current TO old, temp TO current` swaps in one atomic
      # statement (a single metadata lock over all tables), then the old table is
      # dropped. On first build there is no current table, so just rename temp in.
      sig { params(temp_table: String, old_table: String).void }
      def atomic_rename!(temp_table, old_table)
        view = view_class.table_name
        unless view_class.table_exists?
          connection.rename_table(temp_table, view)
          return
        end

        T.unsafe(connection).execute(rename_sql(view => old_table, temp_table => view))
        connection.drop_table(old_table, if_exists: true)
      end

      sig { params(pairs: T::Hash[String, String]).returns(String) }
      def rename_sql(pairs)
        clauses = pairs.map { |from, to| "#{connection.quote_table_name(from)} TO #{connection.quote_table_name(to)}" }
        "RENAME TABLE #{clauses.join(', ')}"
      end
    end
  end
end
