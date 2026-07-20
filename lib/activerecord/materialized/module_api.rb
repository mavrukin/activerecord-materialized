# frozen_string_literal: true

module ActiveRecord
  # Application-level materialized views for Rails/ActiveRecord on databases
  # without native materialized-view support (MySQL, MariaDB, SQLite).
  #
  # Define views by subclassing {Materialized::View}. This module is the
  # top-level entry point for global {configure configuration} and operational
  # helpers such as {verify_schema!}.
  #
  # @see Materialized::View defining a view
  # @see Materialized::Configuration the configurable settings
  module Materialized
    class << self
      @configuration = nil

      # The global configuration object. Prefer {configure} for setting values.
      #
      # @return [Configuration] the current configuration (created on first use)
      def configuration
        config = @configuration
        if config.nil?
          config = Configuration.new
          @configuration = config
        end
        config
      end

      # Configure the gem, typically from an initializer.
      #
      # @example config/initializers/activerecord_materialized.rb
      #   ActiveRecord::Materialized.configure do |config|
      #     config.default_refresh_strategy = :async
      #     config.refresh_dispatcher       = :active_job
      #     config.default_max_staleness    = 12.hours
      #   end
      #
      # @yieldparam config [Configuration]
      # @return [void]
      def configure(&block)
        yield(configuration)
      end

      def metadata_table_name = configuration.metadata_table_name

      def partition_table_name = configuration.partition_table_name

      # Verifies every registered view's cache table still matches the columns its
      # source relation projects — run it at boot or in CI to catch a view whose
      # definition changed without a migration. Never alters tables.
      #
      # @raise [SchemaVerifier::SchemaDriftError] on the first drifted view
      # @return [void]
      def verify_schema!
        registered = Registry.all
        registered.each { |view_class| SchemaVerifier.new(view_class).verify! }
      end

      # Checks every registered view's materialized *contents* against its source
      # relation and returns a {DataVerificationResult} per view (never raises on
      # drift), so callers can alert on or repair the divergent partition keys.
      #
      # @param mode [Symbol] +:row_count+, +:checksum+, or +:full+
      # @param sample [Numeric, nil] verify a random subset (Integer count / Float fraction)
      # @return [Array<DataVerificationResult>]
      def verify_data(mode: :checksum, sample: nil)
        Registry.all.map { |view_class| DataVerifier.new(view_class, mode: mode, sample: sample).verify }
      end

      # Like {verify_data} but raises {DataVerifier::DataDriftError} if any view has
      # drifted — for a boot/CI/cron gate. Returns the results when all are clean.
      #
      # @raise [DataVerifier::DataDriftError] listing the drifted views
      # @return [Array<DataVerificationResult>]
      def verify_data!(mode: :checksum, sample: nil)
        results = verify_data(mode: mode, sample: sample)
        drifted = results.select(&:drifted?)
        return results if drifted.empty?

        raise DataVerifier::DataDriftError, data_drift_message(drifted)
      end

      # Reconciles every registered view — verifies its contents against the source and
      # repairs any drift with scoped maintenance (never a full rebuild), returning a
      # {ReconcileResult} per view. See {Reconciler}.
      #
      # @param mode [Symbol] drift-check depth: +:row_count+, +:checksum+, or +:full+
      # @param sample [Numeric, nil] verify a random subset (Integer count / Float fraction)
      # @return [Array<ReconcileResult>]
      def reconcile!(mode: :checksum, sample: nil)
        Registry.reconcile_all!(mode: mode, sample: sample)
      end

      # Like {reconcile!} but only for stale views — dirty, never refreshed, or past
      # +max_staleness+ — the scheduled bounded-staleness backstop (fresh views are
      # skipped). Drive it from cron or ActiveJob.
      #
      # @param mode [Symbol] drift-check depth: +:row_count+, +:checksum+, or +:full+
      # @param sample [Numeric, nil] verify a random subset (Integer count / Float fraction)
      # @return [Array<ReconcileResult>] one per reconciled (stale) view
      def reconcile_stale!(mode: :checksum, sample: nil)
        Registry.reconcile_stale!(mode: mode, sample: sample)
      end

      # Fans the periodic reconcile backstop across an ActiveJob fleet: enqueues one
      # {ReconcileJob} per stale, materialized view so many workers share the (expensive) drift
      # verification instead of one process running it serially. Run it from a SINGLE owner —
      # a leader, a dedicated instance, or one recurring job — never as cron on every server (see
      # the distributed-deployment guide). Requires ActiveJob; without it, use {reconcile_stale!}.
      #
      # @param mode [Symbol] drift-check depth passed to each job (+:row_count+/+:checksum+/+:full+)
      # @param sample [Numeric, nil] verify a random subset (Integer count / Float fraction)
      # @return [Array<String>] the view keys enqueued
      def enqueue_stale_reconciles!(mode: :checksum, sample: nil)
        enqueue_for_each_stale_view(:enqueue_stale_reconciles!) do |view_class|
          ReconcileJob.perform_later(view_class.view_key, mode: mode, sample: sample)
        end
      end

      # The fan-out form of the serial {Registry.refresh_stale!}: enqueues one {RefreshJob} per
      # stale, materialized view. Same single-owner rule as {enqueue_stale_reconciles!}. Requires ActiveJob.
      #
      # @return [Array<String>] the view keys enqueued
      def enqueue_stale_refreshes!
        enqueue_for_each_stale_view(:enqueue_stale_refreshes!) do |view_class|
          RefreshJob.perform_later(view_class.view_key)
        end
      end

      # Logged once at boot (see {Railtie}) when ActiveJob is available but the effective dispatcher
      # is still the in-process refresher — it does not coordinate across processes, so it is a
      # correctness/efficiency hazard in a multi-process deployment. Silent when dispatching via
      # ActiveJob, and silent when ActiveJob isn't loaded at all (a genuinely single-process app,
      # for which the in-process refresher is the right and only choice).
      #
      # @param logger [#warn, nil] destination (defaults to the Rails logger)
      # @return [void]
      def warn_if_in_process_dispatcher!(logger: default_logger)
        return unless configuration.active_job_available?
        return if configuration.refresh_dispatcher == :active_job

        logger&.warn(IN_PROCESS_DISPATCHER_WARNING)
      end

      # Publishes a committed dependency write from a custom change source (a
      # CDC/replication stream, a bulk loader, another service). It drives the
      # externally-fed views (`change_source :none`) that depend on the table;
      # callback-driven views are left to their own commit callbacks so no view is
      # maintained twice. To recover a callback-driven view after a callback-skipping
      # bulk load, use {mark_dirty_for_tables!} instead.
      #
      # @param change [WriteChange] the committed write to publish
      # @return [void]
      def publish_write_change!(change)
        DependencyRegistry.publish_write_change!(change)
      end

      # Coarse ingestion signal for callers that cannot describe the individual
      # write: enqueues a full recompute for every view depending on any of
      # +tables+ and schedules it per each view's refresh strategy (inline for
      # +:immediate+, in the background for +:async+). Idempotent, so it is safe to
      # call repeatedly and to recover a view after a callback-skipping bulk load.
      #
      # @param tables [Array<String>] dependency table names
      # @return [void]
      def mark_dirty_for_tables!(tables)
        DependencyRegistry.mark_dirty_for_tables!(tables)
      end

      # Ingests a change described as a normalized descriptor — the CDC-friendly
      # entry point for a consumer that has the table, operation, and (optionally)
      # the changed key columns or full before/after images as plain data rather
      # than an ActiveRecord object. Builds a {WriteChange} and publishes it via
      # {publish_write_change!}, so it drives the externally-fed
      # (+change_source :none+) views on the table; a callback-driven view is left
      # to its own callbacks — recover one after a bulk load with
      # {mark_dirty_for_tables!}.
      #
      # Supply +before+/+after+ images when the stream carries them; otherwise
      # +key_attributes+ scopes maintenance to the affected partition(s). With
      # neither — or a partial +:update+ image that cannot identify both the old
      # and new partition — maintenance widens to a full recompute (always correct).
      # See {WriteChange.from_descriptor}.
      #
      # @param table [String] the changed table
      # @param operation [Symbol] +:create+, +:update+, or +:destroy+
      # @param key_attributes [Hash, nil] the GROUP BY key columns of the changed row
      # @param before [Hash, nil] pre-image, for +:update+/+:destroy+
      # @param after [Hash, nil] post-image, for +:create+/+:update+
      # @param source_ts [Integer, nil] optional monotonic source watermark (e.g. a Debezium +ts_ms+ or
      #   a per-key Kafka offset). When given, an affected partition already applied at/after this value
      #   is skipped as provably-stale (best-effort, reconcile-backed), and the view's freshness/lag
      #   becomes observable via {SourceWatermark}. Ignored for callback-driven and full-recompute writes.
      # @param images [Hash] the change images/keys — +key_attributes:+, +before:+, +after:+ (forwarded
      #   to {WriteChange.from_descriptor}, which rejects any unrecognized keyword)
      # @return [void]
      def ingest_change(table:, operation:, source_ts: nil, **images)
        unless source_ts.nil? || source_ts.is_a?(Integer)
          raise ArgumentError,
                "source_ts must be an Integer (e.g. a Debezium ts_ms or a Kafka offset); got #{source_ts.class}"
        end

        change = WriteChange.from_descriptor(table_name: table, operation: operation, **images)
        change = change.with_source_ts(source_ts) if source_ts
        publish_write_change!(change)
      end

      # Relay one Debezium CDC change envelope through {#ingest_change} — mapping +op+ (c/r → create,
      # u → update, d → destroy), the +before+/+after+ row images, and +source.table+ for you (a nested
      # +payload+ is unwrapped). A +nil+ envelope (a Kafka tombstone) is a no-op; a non-tombstone with
      # no +op+, or an unsupported +op+, raises. Pass +table+ to override the target when it differs
      # from +source.table+. +table+ is positional (not a keyword) so an inline envelope literal is not
      # misparsed as keyword arguments. See {DebeziumEnvelope} and the CDC section of the README.
      #
      # @param envelope [Hash, nil] a decoded Debezium change event value (string or symbol keys)
      # @param table [String, Symbol, nil] target-table override; defaults to +source.table+
      # @return [void]
      # @raise [ArgumentError] on a mis-shaped envelope, an unsupported +op+, or an undeterminable table
      def ingest_debezium_change(envelope, table = nil)
        descriptor = DebeziumEnvelope.to_change_descriptor(envelope, table)
        ingest_change(**descriptor) if descriptor
      end

      # Relay pending {WriteOutbox} rows (captured by database triggers for out-of-band writes)
      # through {#ingest_change}, then delete them. The operational entry point run from a poller,
      # cron, or background job when a table has trigger/outbox capture installed. Returns the number
      # of rows relayed so a caller can loop until drained. See +docs/out-of-band-writes.md+.
      #
      # @param limit [Integer, nil] max rows to relay this pass (nil = all pending)
      # @return [Integer]
      def drain_write_outbox!(limit: nil) = WriteOutbox.drain!(limit: limit)

      def atomic_swap_refresh? = configuration.atomic_swap_refresh

      attr_writer :configuration

      private

      # Enqueues one job per stale, *materialized* view and returns their keys. Cold views read
      # through and aren't maintained, so a job for one would only no-op every tick — skip them.
      def enqueue_for_each_stale_view(method_name)
        require_active_job!(method_name)
        Registry.stale_views.select(&:materialized?).map do |view_class|
          yield view_class
          view_class.view_key
        end
      end

      def require_active_job!(method_name)
        return if configuration.active_job_available?

        raise NotImplementedError,
              "#{method_name} requires ActiveJob — load it and set config.refresh_dispatcher = " \
              ":active_job, or run the in-process reconcile_stale! / Registry.refresh_stale! instead."
      end

      def default_logger
        Rails.logger if defined?(Rails) && Rails.respond_to?(:logger)
      end

      def data_drift_message(results)
        summary = results.map do |result|
          "#{result.view_name} (#{result.missing_keys.size} missing, " \
            "#{result.extra_keys.size} extra, #{result.mismatched_keys.size} mismatched)"
        end
        "materialized view data drift detected: #{summary.join('; ')}"
      end
    end

    # Guidance logged when the in-process dispatcher is active in a possibly multi-process
    # deployment. Private — internal wording, not a public contract.
    IN_PROCESS_DISPATCHER_WARNING =
      "[activerecord-materialized] refresh_dispatcher is :async: the in-process refresher is " \
      "single-process-only (queue lost on restart). Use config.refresh_dispatcher = :active_job for multiple servers."
    private_constant :IN_PROCESS_DISPATCHER_WARNING
  end
end
