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
