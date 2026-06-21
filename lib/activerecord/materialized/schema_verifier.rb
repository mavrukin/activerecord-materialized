# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Verifies that a view's provisioned cache table still matches the columns
    # its source relation projects. Raises on drift (e.g. the definition gained
    # or dropped a column but no migration was run) — it never alters the table
    # or rebuilds data.
    class SchemaVerifier
      extend T::Sig

      class SchemaDriftError < StandardError; end

      sig { params(view_class: ViewClass).void }
      def initialize(view_class)
        @view_class = view_class
      end

      # No-op when the cache table has not been provisioned yet (a cold view that
      # has never been migrated/built is not "drifted" — it is simply absent).
      sig { void }
      def verify!
        return unless @view_class.table_exists?

        missing = expected_columns - actual_columns
        extra = actual_columns - expected_columns
        return if missing.empty? && extra.empty?

        Kernel.raise SchemaDriftError, drift_message(missing, extra)
      end

      sig { returns(T::Boolean) }
      def drifted?
        verify!
        false
      rescue SchemaDriftError
        true
      end

      private

      sig { returns(T::Array[String]) }
      def expected_columns
        CacheTableSchema
          .column_definitions(@view_class.connection, @view_class.resolved_source)
          .map(&:name).sort
      end

      sig { returns(T::Array[String]) }
      def actual_columns
        @view_class.connection.columns(@view_class.table_name).map(&:name).reject { |name| name == "id" }.sort
      end

      sig { params(missing: T::Array[String], extra: T::Array[String]).returns(String) }
      def drift_message(missing, extra)
        details = []
        details << "missing columns: #{missing.join(', ')}" if missing.any?
        details << "unexpected columns: #{extra.join(', ')}" if extra.any?
        "#{@view_class.name} cache table #{@view_class.table_name} is out of date " \
          "(#{details.join('; ')}). Generate and run a migration: " \
          "bin/rails generate activerecord_materialized:migration #{@view_class.name}"
      end
    end
  end
end
