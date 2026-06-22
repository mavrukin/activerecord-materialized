# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Global, app-wide defaults, set via {Materialized.configure}. Individual
    # views can override most of these with the corresponding DSL macro.
    class Configuration
      extend T::Sig

      # @return [String] name of the metadata table (default "ar_materialized_view_metadata")
      sig { returns(String) }
      attr_accessor :metadata_table_name

      # @return [String] name of the per-partition freshness table
      sig { returns(String) }
      attr_accessor :partition_table_name

      # @return [Numeric, ActiveSupport::Duration, nil] default {ViewRefreshPolicyClassMethods::ClassMethods#max_staleness max_staleness}
      sig { returns(T.nilable(DebounceInterval)) }
      attr_accessor :default_max_staleness

      # @return [Integer, nil] optional per-refresh timeout in seconds
      sig { returns(T.nilable(Integer)) }
      attr_accessor :refresh_timeout

      # @return [Boolean] whether a full refresh swaps a freshly built table in atomically
      sig { returns(T::Boolean) }
      attr_accessor :atomic_swap_refresh

      # @return [Symbol] default refresh strategy: +:async+, +:immediate+, or +:manual+
      sig { returns(Symbol) }
      attr_accessor :default_refresh_strategy

      # @return [Numeric] default debounce window (seconds) for coalescing async refreshes
      sig { returns(DebounceInterval) }
      attr_accessor :default_refresh_debounce

      # @return [Symbol] background dispatcher: +:async+ (in-process thread) or +:active_job+
      sig { returns(Symbol) }
      attr_accessor :refresh_dispatcher

      # @return [Symbol] ActiveJob queue name used when +refresh_dispatcher+ is +:active_job+
      sig { returns(Symbol) }
      attr_accessor :refresh_queue_name

      # Cold-read behavior: :read_through (serve from source), :serve_stale
      # (serve the cache as-is), or :raise.
      sig { returns(Symbol) }
      attr_accessor :default_cold_read_strategy

      sig { void }
      def initialize
        @metadata_table_name = T.let("ar_materialized_view_metadata", String)
        @partition_table_name = T.let("ar_materialized_view_partitions", String)
        @default_max_staleness = T.let(nil, T.nilable(DebounceInterval))
        @refresh_timeout = T.let(nil, T.nilable(Integer))
        @atomic_swap_refresh = T.let(true, T::Boolean)
        @default_refresh_strategy = T.let(:async, Symbol)
        @default_refresh_debounce = T.let(2, DebounceInterval)
        @refresh_dispatcher = T.let(:async, Symbol)
        @refresh_queue_name = T.let(:materialized_views, Symbol)
        @default_cold_read_strategy = T.let(:read_through, Symbol)
      end
    end
  end
end
