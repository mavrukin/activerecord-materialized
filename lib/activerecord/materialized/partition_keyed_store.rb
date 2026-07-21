# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Shared base for the per-partition stores keyed by (view_name, partition_key): {PartitionState}
    # (the cold-view fresh set) and {SourceWatermark} (the CDC watermark). Centralizes the primitives
    # they must share — most importantly {#serialize}, which has to be identical across every store, or
    # a mark and a watermark would key the same partition differently and lookups would silently miss.
    #
    # A subclass supplies the three things that differ — its {#record_class}, {#table_name}, and the
    # table-specific columns via {#define_columns} — and may override {#ensure_columns!} to lazily add
    # a column introduced after the table was first provisioned.
    #
    # @api private
    class PartitionKeyedStore
      def initialize(view_class)
        @view_class = view_class
      end

      private

      attr_reader :view_class

      # The ActiveRecord model backing this store (e.g. PartitionRecord). Subclasses must override.
      def record_class
        raise NotImplementedError, "#{self.class} must define #record_class"
      end

      # The store's table name. Subclasses must override.
      def table_name
        raise NotImplementedError, "#{self.class} must define #table_name"
      end

      # Add the store's own columns (beyond view_name/partition_key) to the create_table definition.
      # Subclasses must override.
      def define_columns(_table)
        raise NotImplementedError, "#{self.class} must define #define_columns"
      end

      # Lazily add columns introduced after the table was first provisioned, so an app migrated from an
      # earlier version picks them up without a new migration. Default: nothing extra to add.
      def ensure_columns!(_connection); end

      # Serialize a partition-key tuple to its stored form. MUST stay identical across every store, or
      # two stores would key the same partition differently and their lookups would silently miss.
      def serialize(key_tuple)
        key_tuple.map(&:to_s).to_json
      end

      def view_key
        view_class.view_key
      end

      def scope
        record_class.where(view_name: view_key)
      end

      def ensure_table!
        connection = view_class.connection
        return ensure_columns!(connection) if record_class.table_exists?

        connection.create_table(table_name) do |t|
          t.string :view_name, null: false
          t.string :partition_key, null: false
          define_columns(t)
        end
        connection.add_index(table_name, %i[view_name partition_key], unique: true)
        record_class.reset_column_information
      end
    end
  end
end
