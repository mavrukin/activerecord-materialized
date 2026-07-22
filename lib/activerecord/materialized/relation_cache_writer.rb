# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Materializes a relation into a cache table via `INSERT … SELECT`, with an atomic swap on full refresh.
    #
    # @api private
    class RelationCacheWriter
      def initialize(view_class)
        @view_class = view_class
      end

      def bootstrap!(relation)
        CacheTableSchema.ensure_table!(view_class, relation)
        replace_all!(relation)
      end

      def replace_all!(relation)
        view_class.transaction do
          view_class.delete_all
          insert_rows!(relation)
        end
        cache_row_count
      end

      # Scoped in-place maintenance: delete + re-insert only the affected partitions. A full recompute
      # goes through +atomic_swap!+ instead (see IncrementalMaintainer#recompute_all!), so this only
      # ever handles a bounded set of partition keys.
      def replace_partitions!(relation, key_tuples:)
        view_class.transaction do
          delete_partitions!(key_tuples)
          insert_rows!(relation)
        end
        cache_row_count
      end

      def atomic_swap!(relation)
        temp_table = refresh_temp_table_name
        old_table = refresh_old_table_name

        populate_temp_table!(temp_table, relation)
        TableSwap.new(view_class).swap!(temp_table, old_table)

        view_class.reset_column_information
        cache_row_count
      end

      def populate_temp_table!(temp_table, relation)
        CacheTableSchema.create_table!(view_class, temp_table, relation)
        temp_model = temporary_model(temp_table)
        self.class.new(temp_model).replace_all!(relation)
      end

      def refresh_temp_table_name
        "#{view_class.table_name}_refresh_#{SecureRandom.hex(4)}"
      end

      def refresh_old_table_name
        "#{view_class.table_name}_old_#{SecureRandom.hex(4)}"
      end

      private

      attr_reader :view_class

      # Count straight from the cache table, bypassing the View read routing
      # (during a rebuild the view is not warm yet, so a routed count would read
      # through to the source).
      def cache_row_count
        view_class.unscoped.count
      end

      def delete_partitions!(key_tuples)
        materialized_view = view_class
        materialized_view.view_definition.partition_scope_on(view_class, key_tuples).delete_all
      end

      # INSERT ... SELECT entirely in the database; the result set never crosses
      # into Ruby. Cache columns share the relation's projection order, so the
      # SELECT list maps onto them positionally.
      def insert_rows!(relation)
        columns = view_class.column_names - ["id"]
        return if columns.empty?

        view_class.connection.execute(insert_select_sql(relation, columns))
      end

      def insert_select_sql(relation, columns)
        manager = Arel::InsertManager.new
        manager.into(view_class.arel_table)
        manager.columns.concat(columns.map { |name| view_class.arel_table[name] })
        manager.select(Arel.sql(relation.to_sql))
        manager.to_sql
      end

      def temporary_model(table_name)
        klass = Class.new(::ActiveRecord::Base)
        klass.table_name = table_name
        klass
      end
    end
  end
end
