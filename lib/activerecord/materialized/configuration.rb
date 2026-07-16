# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Global, app-wide defaults, set via {Materialized.configure}. Individual
    # views can override most of these with the corresponding DSL macro.
    class Configuration
      # @return [String] name of the metadata table (default "ar_materialized_view_metadata")
      attr_accessor :metadata_table_name

      # @return [String] name of the per-partition freshness table
      attr_accessor :partition_table_name

      # @return [Numeric, ActiveSupport::Duration, nil] default {ViewRefreshPolicyClassMethods::ClassMethods#max_staleness max_staleness}
      attr_accessor :default_max_staleness

      # @return [Integer, nil] optional per-refresh timeout in seconds
      attr_accessor :refresh_timeout

      # @return [Boolean] whether a full refresh swaps a freshly built table in atomically
      attr_accessor :atomic_swap_refresh

      # @return [Symbol] default refresh strategy: +:async+, +:immediate+, or +:manual+
      attr_accessor :default_refresh_strategy

      # @return [Numeric] default debounce window (seconds) for coalescing async refreshes
      attr_accessor :default_refresh_debounce

      # @return [Symbol] background dispatcher: +:async+ (in-process thread) or +:active_job+
      attr_accessor :refresh_dispatcher

      # @return [Symbol] ActiveJob queue name used when +refresh_dispatcher+ is +:active_job+
      attr_accessor :refresh_queue_name

      # Cold-read behavior: :read_through (serve from source), :serve_stale
      # (serve the cache as-is), or :raise.
      attr_accessor :default_cold_read_strategy

      # Default change source for views: +:callbacks+ (install ActiveRecord
      # commit callbacks on +depends_on+ models) or +:none+ (install no
      # callbacks; drive maintenance through the public ingestion API from an
      # external adapter). A view can override this with +change_source+.
      # Lazily defaulted (like +max_tracked_partitions+) so it stays out of
      # +initialize+.
      #
      # @return [Symbol]
      def default_change_source=(value)
        @default_change_source = ChangeSource.cast(value)
      end

      def default_change_source
        @default_change_source ||= ChangeSource::CALLBACKS
      end

      # Cap on distinct partitions tracked in a view's pending maintenance before
      # it collapses to a single full recompute. Bounds the per-write cost of a
      # bulk write that spans many partitions. Defaults to 1000.
      #
      # @return [Integer]
      attr_writer :max_tracked_partitions

      def max_tracked_partitions
        @max_tracked_partitions ||= 1_000
      end

      def initialize
        @metadata_table_name = "ar_materialized_view_metadata"
        @partition_table_name = "ar_materialized_view_partitions"
        @default_max_staleness = nil
        @refresh_timeout = nil
        @atomic_swap_refresh = true
        @default_refresh_strategy = :async
        @default_refresh_debounce = 2
        @refresh_dispatcher = :async
        @refresh_queue_name = :materialized_views
        @default_cold_read_strategy = :read_through
      end
    end
  end
end
