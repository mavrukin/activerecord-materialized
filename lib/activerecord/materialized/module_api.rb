# typed: strict
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
      extend T::Sig

      @configuration = T.let(nil, T.nilable(Configuration))

      # The global configuration object. Prefer {configure} for setting values.
      #
      # @return [Configuration] the current configuration (created on first use)
      sig { returns(Configuration) }
      def configuration
        config = @configuration
        if config.nil?
          config = Configuration.new
          @configuration = T.let(config, T.nilable(Configuration))
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
      sig { params(block: T.proc.params(config: Configuration).void).void }
      def configure(&block)
        yield(configuration)
      end

      sig { returns(String) }
      def metadata_table_name
        configuration.metadata_table_name
      end

      sig { returns(String) }
      def partition_table_name
        configuration.partition_table_name
      end

      # Verifies every registered view's cache table still matches the columns its
      # source relation projects — run it at boot or in CI to catch a view whose
      # definition changed without a migration. Never alters tables.
      #
      # @raise [SchemaVerifier::SchemaDriftError] on the first drifted view
      # @return [void]
      sig { void }
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
      sig { params(mode: Symbol, sample: T.nilable(Numeric)).returns(T::Array[DataVerificationResult]) }
      def verify_data(mode: :checksum, sample: nil)
        Registry.all.map { |view_class| DataVerifier.new(view_class, mode: mode, sample: sample).verify }
      end

      # Like {verify_data} but raises {DataVerifier::DataDriftError} if any view has
      # drifted — for a boot/CI/cron gate. Returns the results when all are clean.
      #
      # @raise [DataVerifier::DataDriftError] listing the drifted views
      # @return [Array<DataVerificationResult>]
      sig { params(mode: Symbol, sample: T.nilable(Numeric)).returns(T::Array[DataVerificationResult]) }
      def verify_data!(mode: :checksum, sample: nil)
        results = verify_data(mode: mode, sample: sample)
        drifted = results.select(&:drifted?)
        return results if drifted.empty?

        raise DataVerifier::DataDriftError, data_drift_message(drifted)
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
      sig { params(change: WriteChange).void }
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
      sig { params(tables: T::Array[String]).void }
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
      # @return [void]
      sig do
        params(
          table: String,
          operation: WriteChange::Operation,
          key_attributes: T.nilable(WriteChange::AttributeInput),
          before: T.nilable(WriteChange::AttributeInput),
          after: T.nilable(WriteChange::AttributeInput)
        ).void
      end
      def ingest_change(table:, operation:, key_attributes: nil, before: nil, after: nil)
        publish_write_change!(
          WriteChange.from_descriptor(
            table_name: table, operation: operation,
            key_attributes: key_attributes, before: before, after: after
          )
        )
      end

      sig { returns(T::Boolean) }
      def atomic_swap_refresh?
        configuration.atomic_swap_refresh
      end

      sig { params(value: Configuration).void }
      def configuration=(value)
        @configuration = T.let(value, T.nilable(Configuration))
      end

      private

      sig { params(results: T::Array[DataVerificationResult]).returns(String) }
      def data_drift_message(results)
        summary = results.map do |result|
          "#{result.view_name} (#{result.missing_keys.size} missing, " \
            "#{result.extra_keys.size} extra, #{result.mismatched_keys.size} mismatched)"
        end
        "materialized view data drift detected: #{summary.join('; ')}"
      end
    end
  end
end
