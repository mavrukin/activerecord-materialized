# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Incremental-maintenance DSL mixed into a {View}: `refresh_mode`, `incremental_keys`,
    # `incremental_from`, and the per-write maintenance entry points.
    module ViewIncrementalClassMethods
      # Maps a dependency-table write to the partition key(s) it affects.

      def self.included(base)
        base.extend(ClassMethods)
      end

      # The incremental-maintenance DSL methods available on a {View} subclass.
      module ClassMethods
        def view_class
          self
        end

        # Sets whether maintenance is incremental (default) or a full recompute on every change.
        #
        # @param mode [Symbol] +:incremental+ (default) or +:full+
        # @return [void]
        def refresh_mode(mode)
          instance_variable_set(:@refresh_mode, mode.to_sym)
        end

        # Overrides the source relation used for incremental maintenance (defaults to +materialized_from+).
        #
        # @yieldreturn [ActiveRecord::Relation] the relation to maintain incrementally
        # @return [void]
        def incremental_from(&block)
          @incremental_source_definition = block
        end

        # Declares the explicit GROUP BY key columns used to scope incremental maintenance.
        #
        # @param columns [Array<Symbol>] the key columns identifying a partition
        # @return [void]
        def incremental_keys(*columns)
          @incremental_key_columns = columns.map(&:to_s)
        end

        # Maps a write on `table` to the partition key(s) it affects — for a view
        # whose GROUP BY key lives on a joined/parent table, so the written row's own
        # payload can't supply it. The block receives the {WriteChange} and returns
        # the key value(s): a scalar (or array of scalars) for a single-column key, a
        # tuple (or array of tuples) for a composite key; returning nothing falls back
        # to a full recompute. Trades a small lookup per write for avoiding one.
        #
        # @param table [Symbol, String] the dependency table the resolver applies to
        # @yieldparam change [WriteChange] the committed write on +table+
        # @yieldreturn [Object, Array, nil] the affected partition key(s), or +nil+ to force a full recompute
        # @return [void]
        def partition_key_for(table, &block)
          partition_key_resolvers[table.to_s] = block
        end

        def partition_key_resolver_for(table_name)
          partition_key_resolvers[table_name]
        end

        def partition_key_resolvers
          @partition_key_resolvers ||= {}
        end

        def resolved_refresh_mode
          mode = instance_variable_get(:@refresh_mode)
          mode || :incremental
        end

        def view_definition
          ViewDefinition.new(
            view_class.resolved_source,
            explicit_group_keys: incremental_key_columns.presence
          )
        end

        def maintenance_key_columns
          return incremental_key_columns if incremental_key_columns.any?

          view_definition.group_key_columns
        end

        def incrementally_maintainable?
          resolved_refresh_mode != :full && view_definition.incrementally_maintainable?
        end

        def aggregate_analysis
          AggregateAnalysis.new(view_class.resolved_source)
        end

        # A warm view with all-distributive aggregates uses summary-delta IVM;
        # otherwise writes drive scoped recompute. Restricted to callback-backed
        # views: their in-app writes arrive exactly once, so applying signed deltas
        # is safe. Externally fed views recompute their partitions instead, so
        # at-least-once or duplicate delivery converges rather than double-counting.
        def delta_maintaining?
          resolved_refresh_mode != :full &&
            view_class.resolved_change_source == ChangeSource::CALLBACKS &&
            view_class.materialized? &&
            aggregate_analysis.delta_maintainable?
        end

        def incremental_source_override?
          !@incremental_source_definition.nil?
        end

        def record_write_change!(change)
          WriteMaintenance.new(view_class).record!(change)
        end

        def incremental_key_columns
          columns = instance_variable_get(:@incremental_key_columns)
          columns.nil? ? [] : columns
        end

        def resolved_incremental_source
          unless incremental_source_override?
            Kernel.raise ArgumentError,
                         "incremental_from override is not configured for #{view_class.name || view_class.view_key}"
          end

          view_class.send(
            :resolve_source_definition,
            @incremental_source_definition,
            "incremental_from is required for #{view_class.name || view_class.view_key}"
          )
        end
      end
    end
  end
end
