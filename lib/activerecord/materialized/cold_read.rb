# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # The relation a read is served from when a view is not yet materialized,
    # per its cold_read strategy. Read-through wraps the live source as a derived
    # table aliased to the cache table name, so where/order/limit/count keep
    # working against the same column names.
    class ColdRead
      extend T::Sig

      sig { params(view_class: ViewClass).void }
      def initialize(view_class)
        @view_class = view_class
      end

      sig { returns(T.untyped) }
      def scope
        case @view_class.resolved_cold_read_strategy
        when :read_through
          ensure_skeleton!
          unscoped.from(source_derived_table)
        when :serve_stale
          ensure_skeleton!
          unscoped
        when :raise
          Kernel.raise NotMaterializedError, not_materialized_message
        else
          Kernel.raise ArgumentError, "Unknown cold_read strategy: #{@view_class.resolved_cold_read_strategy}"
        end
      end

      private

      sig { returns(T.untyped) }
      def unscoped
        T.unsafe(@view_class).unscoped
      end

      sig { returns(Arel::Nodes::SqlLiteral) }
      def source_derived_table
        Arel.sql("(#{@view_class.resolved_source.to_sql}) #{@view_class.quoted_table_name}")
      end

      # Provisions an empty cache table for column metadata — cheap DDL, no data.
      sig { void }
      def ensure_skeleton!
        return if @view_class.table_exists?

        CacheTableSchema.ensure_table!(@view_class, @view_class.resolved_source)
      end

      sig { returns(String) }
      def not_materialized_message
        "#{@view_class.name} is not materialized; run #{@view_class.name}.rebuild!(confirm: true)"
      end
    end
  end
end
