# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Inspects a source relation for its GROUP BY maintenance keys and builds partition scopes.
    #
    # @api private
    class ViewDefinition
      extend T::Sig

      sig do
        params(
          source: ::ActiveRecord::Relation,
          explicit_group_keys: T.nilable(T::Array[String])
        ).void
      end
      def initialize(source, explicit_group_keys: nil)
        @source = source
        @explicit_group_keys = explicit_group_keys
      end

      sig { returns(T::Boolean) }
      def incrementally_maintainable?
        group_key_columns.any?
      end

      sig { returns(T::Array[String]) }
      def group_key_columns
        @group_key_columns = T.let(@group_key_columns, T.nilable(T::Array[String]))
        @group_key_columns ||= resolve_group_key_columns
      end

      # Restrict a model/cache table to the given partitions. The partition
      # columns are real columns on `model`, so qualify them to its own table.
      sig do
        params(
          model: T.class_of(::ActiveRecord::Base),
          key_tuples: T::Array[T::Array[T.untyped]]
        ).returns(::ActiveRecord::Relation)
      end
      def partition_scope_on(model, key_tuples)
        validate_partition_keys!(key_tuples)
        attributes = group_key_columns.map { |column| T.unsafe(model).arel_table[column] }
        filter_partitions(model.unscoped, attributes, key_tuples)
      end

      # Restrict the source relation to the given partitions. Qualify each key to
      # its GROUP BY attribute's own table, which may be a joined table (e.g.
      # `name.gender`) rather than the source's base table.
      sig { params(key_tuples: T::Array[T::Array[T.untyped]]).returns(::ActiveRecord::Relation) }
      def partition_scope(key_tuples)
        validate_partition_keys!(key_tuples)
        base = T.unsafe(source).klass.arel_table
        attributes = group_key_columns.map { |column| group_attributes[column] || base[column] }
        filter_partitions(source, attributes, key_tuples)
      end

      private

      sig { returns(::ActiveRecord::Relation) }
      attr_reader :source

      sig { returns(T::Array[String]) }
      def resolve_group_key_columns
        return @explicit_group_keys if @explicit_group_keys&.any?

        relation_group_columns
      end

      sig { returns(T::Array[String]) }
      def relation_group_columns
        source.group_values.filter_map { |group_value| group_column_name(group_value) }
      end

      sig { params(group_value: T.untyped).returns(T.nilable(String)) }
      def group_column_name(group_value)
        case group_value
        when String, Symbol
          group_value.to_s
        when ::Arel::Attributes::Attribute
          T.unsafe(group_value).name.to_s
        else
          group_value.to_s if group_value.respond_to?(:to_s)
        end
      end

      sig { params(key_tuples: T::Array[T::Array[T.untyped]]).void }
      def validate_partition_keys!(key_tuples)
        raise ArgumentError, "scoped maintenance requires GROUP BY keys" unless incrementally_maintainable?
        raise ArgumentError, "scoped maintenance requires at least one partition key" if key_tuples.empty?
      end

      # GROUP BY attributes keyed by name; an Arel attribute carries its real
      # table (e.g. a joined `name.gender`) that the bare base table column lacks.
      sig { returns(T::Hash[String, T.untyped]) }
      def group_attributes
        @group_attributes = T.let(@group_attributes, T.nilable(T::Hash[String, T.untyped]))
        @group_attributes ||= T.unsafe(source).group_values.each_with_object({}) do |value, map|
          map[T.unsafe(value).name.to_s] = value if value.is_a?(::Arel::Attributes::Attribute)
        end
      end

      sig do
        params(
          scope: ::ActiveRecord::Relation,
          attributes: T::Array[T.untyped],
          key_tuples: T::Array[T::Array[T.untyped]]
        ).returns(::ActiveRecord::Relation)
      end
      def filter_partitions(scope, attributes, key_tuples)
        return multi_partition_filter(scope, attributes, key_tuples) if attributes.size > 1

        scope.where(T.unsafe(attributes.fetch(0)).in(key_tuples.map(&:first)))
      end

      sig do
        params(
          scope: ::ActiveRecord::Relation, attributes: T::Array[T.untyped],
          key_tuples: T::Array[T::Array[T.untyped]]
        ).returns(::ActiveRecord::Relation)
      end
      def multi_partition_filter(scope, attributes, key_tuples)
        key_tuples.reduce(T.unsafe(nil)) do |merged_scope, tuple|
          branch = attributes.each_with_index.reduce(scope) do |relation, (attribute, index)|
            relation.where(T.unsafe(attribute).eq(tuple[index]))
          end
          merged_scope.nil? ? branch : merged_scope.or(branch)
        end
      end
    end
  end
end
