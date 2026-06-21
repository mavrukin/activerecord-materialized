# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class << self
      extend T::Sig

      @configuration = T.let(nil, T.nilable(Configuration))

      sig { returns(Configuration) }
      def configuration
        config = @configuration
        if config.nil?
          config = Configuration.new
          @configuration = T.let(config, T.nilable(Configuration))
        end
        config
      end

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

      # Verifies every registered view's cache table still matches its source
      # relation; raises SchemaVerifier::SchemaDriftError on the first mismatch.
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
