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

      sig { returns(T::Boolean) }
      def atomic_swap_refresh?
        configuration.atomic_swap_refresh
      end

      sig { params(value: Configuration).void }
      def configuration=(value)
        @configuration = T.let(value, T.nilable(Configuration))
      end
    end
  end
end
