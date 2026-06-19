# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class RelationCacheWriter
      extend T::Sig

      sig { params(view_class: T.class_of(::ActiveRecord::Base)).void }
      def initialize(view_class)
        @view_class = view_class
      end

      sig { params(relation: ::ActiveRecord::Relation).returns(Integer) }
      def bootstrap!(relation)
        CacheTableSchema.ensure_table!(view_class, relation)
        replace_all!(relation)
      end

      sig { params(relation: ::ActiveRecord::Relation).returns(Integer) }
      def replace_all!(relation)
        view_class.transaction do
          view_class.delete_all
          insert_rows!(relation)
        end
        view_class.count
      end

      sig do
        params(
          relation: ::ActiveRecord::Relation,
          key_tuples: T::Array[T::Array[String]],
          full_partition: T::Boolean
        ).returns(Integer)
      end
      def replace_partitions!(relation, key_tuples:, full_partition:)
        view_class.transaction do
          if full_partition
            view_class.delete_all
          else
            delete_partitions!(key_tuples)
          end
          insert_rows!(relation)
        end
        view_class.count
      end

      sig { params(relation: ::ActiveRecord::Relation).returns(Integer) }
      def atomic_swap!(relation)
        connection = view_class.connection
        temp_table = refresh_temp_table_name
        old_table = refresh_old_table_name

        populate_temp_table!(temp_table, relation)
        swap_tables!(connection, temp_table, old_table)

        view_class.reset_column_information
        view_class.count
      end

      sig { params(temp_table: String, relation: ::ActiveRecord::Relation).void }
      def populate_temp_table!(temp_table, relation)
        CacheTableSchema.create_table!(T.cast(view_class, ViewClass), temp_table, relation)
        temp_model = temporary_model(temp_table)
        self.class.new(temp_model).replace_all!(relation)
      end

      sig { params(connection: Connection, temp_table: String, old_table: String).void }
      def swap_tables!(connection, temp_table, old_table)
        connection.transaction do
          connection.rename_table(view_class.table_name, old_table) if view_class.table_exists?
          connection.rename_table(temp_table, view_class.table_name)
          connection.drop_table(old_table, if_exists: true)
        end
      end

      sig { returns(String) }
      def refresh_temp_table_name
        "#{view_class.table_name}_refresh_#{SecureRandom.hex(4)}"
      end

      sig { returns(String) }
      def refresh_old_table_name
        "#{view_class.table_name}_old_#{SecureRandom.hex(4)}"
      end

      private

      sig { returns(T.class_of(::ActiveRecord::Base)) }
      attr_reader :view_class

      sig { params(key_tuples: T::Array[T::Array[String]]).void }
      def delete_partitions!(key_tuples)
        materialized_view = T.cast(view_class, ViewClass)
        materialized_view.view_definition.partition_scope_on(view_class, key_tuples).delete_all
      end

      sig { params(relation: ::ActiveRecord::Relation).void }
      def insert_rows!(relation)
        rows = relation_rows(relation)
        # Bulk cache writes intentionally bypass validations.
        view_class.insert_all(rows) if rows.any? # rubocop:disable Rails/SkipsModelValidations
      end

      sig { params(relation: ::ActiveRecord::Relation).returns(T::Array[T::Hash[String, T.untyped]]) }
      def relation_rows(relation)
        column_names = view_class.column_names - ["id"]
        relation.map do |record|
          record.attributes.slice(*column_names)
        end
      end

      sig { params(table_name: String).returns(T.class_of(::ActiveRecord::Base)) }
      def temporary_model(table_name)
        klass = Class.new(::ActiveRecord::Base)
        T.unsafe(klass).table_name = table_name
        klass
      end
    end
  end
end
