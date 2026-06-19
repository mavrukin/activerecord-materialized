# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
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

      sig do
        params(
          model: T.class_of(::ActiveRecord::Base),
          key_tuples: T::Array[T::Array[T.untyped]]
        ).returns(::ActiveRecord::Relation)
      end
      def partition_scope_on(model, key_tuples)
        validate_partition_keys!(key_tuples)
        build_partition_scope(model.unscoped, key_tuples)
      end

      sig { params(key_tuples: T::Array[T::Array[T.untyped]]).returns(::ActiveRecord::Relation) }
      def partition_scope(key_tuples)
        validate_partition_keys!(key_tuples)
        build_partition_scope(source, key_tuples)
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

      sig do
        params(
          scope: ::ActiveRecord::Relation,
          key_tuples: T::Array[T::Array[T.untyped]]
        ).returns(::ActiveRecord::Relation)
      end
      def build_partition_scope(scope, key_tuples)
        columns = group_key_columns
        if columns.size == 1
          column = columns.fetch(0)
          return scope.where(column => key_tuples.map(&:first))
        end

        key_tuples.reduce(T.unsafe(nil)) do |merged_scope, tuple|
          attributes = columns.each_with_index.to_h { |column, index| [column, tuple[index]] }
          branch = scope.where(attributes)
          merged_scope.nil? ? branch : merged_scope.or(branch)
        end
      end
    end
  end
end
