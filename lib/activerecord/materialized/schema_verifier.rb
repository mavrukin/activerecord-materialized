# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Raises when a provisioned cache table no longer matches the columns its
    # source relation projects (drift); never alters the table or rebuilds data.
    class SchemaVerifier
      # Raised when a cache table no longer matches the columns its source relation projects.
      class SchemaDriftError < StandardError; end

      def initialize(view_class)
        @view_class = view_class
      end

      # An unprovisioned cache table is absent, not drifted, so this is a no-op.
      def verify!
        return unless @view_class.table_exists?

        missing = expected_columns - actual_columns
        extra = actual_columns - expected_columns
        return if missing.empty? && extra.empty?

        Kernel.raise SchemaDriftError, drift_message(missing, extra)
      end

      def drifted?
        verify!
        false
      rescue SchemaDriftError
        true
      end

      private

      def expected_columns
        CacheTableSchema
          .column_definitions(@view_class.connection, @view_class.resolved_source)
          .map(&:name).sort
      end

      def actual_columns
        @view_class.connection.columns(@view_class.table_name).map(&:name).reject { |name| name == "id" }.sort
      end

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
