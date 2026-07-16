# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Inspects a source relation for its GROUP BY maintenance keys and builds partition scopes.
    #
    # @api private
    class ViewDefinition
      def initialize(source, explicit_group_keys: nil)
        @source = source
        @explicit_group_keys = explicit_group_keys
      end

      def incrementally_maintainable?
        group_key_columns.any?
      end

      def group_key_columns
        @group_key_columns ||= resolve_group_key_columns
      end

      # Restrict a model/cache table to the given partitions. The partition
      # columns are real columns on `model`, so qualify them to its own table.
      def partition_scope_on(model, key_tuples)
        validate_partition_keys!(key_tuples)
        # On the cache/model table the key is the projected column, so a qualified
        # GROUP BY name (e.g. "authors.country") maps to the bare column ("country").
        attributes = group_key_columns.map { |column| model.arel_table[unqualified(column)] }
        PartitionFilter.new(attributes, key_tuples).apply(model.unscoped)
      end

      # Restrict the source relation to the given partitions. Qualify each key to
      # its GROUP BY attribute's own table, which may be a joined table (e.g.
      # `name.gender`) rather than the source's base table.
      def partition_scope(key_tuples)
        validate_partition_keys!(key_tuples)
        base = source.klass.arel_table
        attributes = group_key_columns.map { |column| source_attribute(column, base) }
        PartitionFilter.new(attributes, key_tuples).apply(source)
      end

      private

      # The Arel attribute for a GROUP BY key on the source side: the captured Arel
      # attribute if the key was given as one; otherwise a qualified string like
      # "authors.country" builds that table's attribute, and a bare name uses the
      # source's base table.
      def source_attribute(column, base)
        return group_attributes[column] if group_attributes.key?(column)

        table, separator, name = column.rpartition(".")
        separator.empty? ? base[column] : ::Arel::Table.new(table)[name]
      end

      # The bare column name, dropping any "table." qualifier.
      def unqualified(column)
        column.rpartition(".").last
      end

      attr_reader :source

      def resolve_group_key_columns
        return @explicit_group_keys if @explicit_group_keys&.any?

        relation_group_columns
      end

      def relation_group_columns
        source.group_values.filter_map { |group_value| group_column_name(group_value) }
      end

      def group_column_name(group_value)
        case group_value
        when String, Symbol
          group_value.to_s
        when ::Arel::Attributes::Attribute
          group_value.name.to_s
        else
          group_value.to_s if group_value.respond_to?(:to_s)
        end
      end

      def validate_partition_keys!(key_tuples)
        raise ArgumentError, "scoped maintenance requires GROUP BY keys" unless incrementally_maintainable?
        raise ArgumentError, "scoped maintenance requires at least one partition key" if key_tuples.empty?
      end

      # GROUP BY attributes keyed by name; an Arel attribute carries its real
      # table (e.g. a joined `name.gender`) that the bare base table column lacks.
      def group_attributes
        @group_attributes ||= source.group_values.each_with_object({}) do |value, map|
          map[value.name.to_s] = value if value.is_a?(::Arel::Attributes::Attribute)
        end
      end
    end
  end
end
