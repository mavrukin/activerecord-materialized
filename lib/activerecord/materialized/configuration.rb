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

      # @return [String] name of the write-outbox table (the optional trigger/outbox change source)
      attr_accessor :write_outbox_table_name

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

      # Background dispatcher: +:active_job+ or +:async+ (in-process thread). Unset, it resolves
      # to +:active_job+ when ActiveJob is loaded and +:async+ otherwise; an explicit assignment
      # always wins. The in-process +:async+ dispatcher does not coordinate across processes and
      # its queue is lost on restart, so it is single-process-only — multi-process deployments
      # should run +:active_job+.
      #
      # @return [Symbol]
      attr_writer :refresh_dispatcher

      def refresh_dispatcher
        @refresh_dispatcher || (active_job_available? ? :active_job : :async)
      end

      # @return [Symbol] ActiveJob queue name used when +refresh_dispatcher+ is +:active_job+
      attr_accessor :refresh_queue_name

      # ActiveJob queue for {ReconcileJob} (the reconcile fan-out); falls back to
      # +refresh_queue_name+ when unset so both maintenance jobs share a queue by default.
      #
      # @return [Symbol]
      attr_writer :reconcile_queue_name

      def reconcile_queue_name
        @reconcile_queue_name || refresh_queue_name
      end

      # Rails multi-database role that maintenance writes (refresh/reconcile/rebuild) run under, so
      # they target the primary in a writer/replica topology. +nil+ (default) yields on the current
      # connection — no routing. Requires the host app to have declared the role via +connects_to+.
      #
      # @return [Symbol, nil]
      attr_accessor :maintenance_role

      # Rails multi-database role that {DataVerifier} reads run under, so the (expensive) drift
      # verification can be offloaded to a replica — the verify-on-replica / repair-on-primary split.
      # +nil+ (default) yields on the current connection.
      #
      # @return [Symbol, nil]
      attr_accessor :verification_role

      # Replication lag budget folded into time-based staleness: a view read from a replica is
      # effectively `view staleness + replication lag` stale, so this tightens the effective
      # +max_staleness+ (a view goes stale this much sooner) to keep replica reads within budget.
      # Keep it well below your smallest +max_staleness+ — a value at or above it drives the effective
      # window to zero, making that view perpetually stale (reconciled every tick). Defaults to 0 (no
      # adjustment); a static estimate of a dynamic quantity — see the distributed-deployment guide.
      #
      # @return [Numeric, ActiveSupport::Duration]
      attr_accessor :replica_lag

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
        @write_outbox_table_name = "ar_materialized_view_write_outbox"
        @default_max_staleness = nil
        @refresh_timeout = nil
        @atomic_swap_refresh = true
        @default_refresh_strategy = :async
        @default_refresh_debounce = 2
        # @refresh_dispatcher intentionally unset — lazily resolved from ActiveJob availability.
        @refresh_queue_name = :materialized_views
        @default_cold_read_strategy = :read_through
        @replica_lag = 0
      end

      # Whether ActiveJob is loaded — the single source of truth for the dispatcher default and
      # the module's dispatch/enqueue guards. Extracted (rather than an inline +defined?+) so it is
      # testable regardless of whether the host app pulled in ActiveJob.
      #
      # @return [Boolean]
      def active_job_available?
        !defined?(ActiveJob::Base).nil?
      end
    end
  end
end
