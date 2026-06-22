# typed: strict
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
      extend T::Sig
      include RefreshCallbacks
      include ViewConfigurationClassMethods
      include ViewQueryAccessClassMethods

      self.abstract_class = true

      class << self
        extend T::Sig

        @source_definition = T.let(nil, T.nilable(SourceDefinition))
        @max_staleness_setting = T.let(nil, T.nilable(T.any(StalenessDuration, Proc)))
        @dependency_tables = T.let(nil, T.nilable(T::Array[String]))
        @refresh_strategy = T.let(nil, T.nilable(Symbol))
        @refresh_debounce = T.let(nil, T.nilable(DebounceInterval))
        @refresh_mode = T.let(nil, T.nilable(RefreshMode))
        @incremental_source_definition = T.let(nil, T.nilable(SourceDefinition))
        @incremental_key_columns = T.let(nil, T.nilable(T::Array[String]))
        @table_name = T.let(nil, T.nilable(String))

        sig { returns(T.nilable(SourceDefinition)) }
        attr_reader :source_definition

        sig { returns(T.nilable(T.any(StalenessDuration, Proc))) }
        attr_reader :max_staleness_setting

        sig { returns(T::Array[String]) }
        def dependency_tables
          tables = T.let(T.unsafe(self).instance_variable_get(:@dependency_tables), T.nilable(T::Array[String]))
          tables.nil? ? [] : tables
        end
      end

      sig { returns(T::Boolean) }
      def stale?
        T.bind(self, View)
        self.class.stale?
      end
    end
  end
end
