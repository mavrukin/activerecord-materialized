# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # The base class for an application-level materialized view. Subclass it,
    # point {ViewConfigurationClassMethods::ClassMethods#materialized_from} at an
    # `ActiveRecord::Relation`, declare the models it
    # {ViewConfigurationClassMethods::ClassMethods#depends_on depends_on}, and then
    # read it like any ActiveRecord model. Reads are served from a cache table the
    # gem maintains incrementally as the underlying data changes; a full
    # materialization happens only via an explicit
    # {ViewQueryAccessClassMethods::ClassMethods#rebuild! rebuild!}, and until then
    # reads transparently fall through to the source query.
    #
    # @example Define a view and use it
    #   class RegionRevenue < ActiveRecord::Materialized::View
    #     extend ActiveRecord::Materialized::QueryExpressions
    #     self.table_name = "mv_region_revenue"
    #
    #     materialized_from do
    #       sales = Sale.arel_table
    #       Sale.group(:region).select(sales[:region], sum_as(sales[:amount], as: :revenue))
    #     end
    #
    #     depends_on Sale            # writes to Sale schedule maintenance
    #     refresh_on_change :async   # refresh in the background after commit
    #     max_staleness 6.hours      # optional time-based safety net
    #   end
    #
    #   RegionRevenue.rebuild!(confirm: true)              # materialize once (e.g. at deploy)
    #   RegionRevenue.where(region: "west").pick(:revenue) # served from the cache table
    #
    # @see ViewConfigurationClassMethods::ClassMethods +materialized_from+ / +depends_on+ DSL
    # @see ViewRefreshPolicyClassMethods::ClassMethods refresh strategy, staleness, and warm-up
    # @see ViewIncrementalClassMethods::ClassMethods incremental-maintenance configuration
    # @see ViewQueryAccessClassMethods::ClassMethods +rebuild!+, +refresh!+, +materialized?+, …
    class View < ::ActiveRecord::Base
      include RefreshCallbacks
      include ViewConfigurationClassMethods
      include ViewQueryAccessClassMethods

      self.abstract_class = true

      class << self
        @source_definition = nil
        @max_staleness_setting = nil
        @dependency_tables = nil
        @refresh_strategy = nil
        @refresh_debounce = nil
        @refresh_mode = nil
        @incremental_source_definition = nil
        @incremental_key_columns = nil
        @table_name = nil

        attr_reader :source_definition, :max_staleness_setting

        def dependency_tables
          tables = instance_variable_get(:@dependency_tables)
          tables.nil? ? [] : tables
        end
      end

      def stale?
        self.class.stale?
      end
    end
  end
end
