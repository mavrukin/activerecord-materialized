# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class << self
      attr_writer :configuration

      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration)
      end

      def metadata_table_name
        configuration.metadata_table_name
      end

      def atomic_swap_refresh?
        configuration.atomic_swap_refresh
      end
    end
  end
end

require "active_record"
require "active_support/concern"
require "active_support/core_ext/string/inflections"
require "active_support/core_ext/module/delegation"
require "active_support/core_ext/integer/time"
require "active_support/core_ext/object/blank"
require "securerandom"

require_relative "activerecord/materialized/configuration"
require_relative "activerecord/materialized/refresh_callbacks"
require_relative "activerecord/materialized/dependency_registry"
require_relative "activerecord/materialized/transaction_refresh_recorder"
require_relative "activerecord/materialized/async_refresher"
require_relative "activerecord/materialized/refresh_scheduler"
require_relative "activerecord/materialized/registry"
require_relative "activerecord/materialized/metadata"
require_relative "activerecord/materialized/refresher"
require_relative "activerecord/materialized/change_subscriber"
require_relative "activerecord/materialized/install_hooks"
require_relative "activerecord/materialized/view"

if defined?(ActiveJob::Base)
  require_relative "activerecord/materialized/refresh_job"
end

ActiveSupport.on_load(:active_record) do
  ActiveRecord::Materialized::InstallHooks.install!
end

if defined?(ActiveRecord::Base)
  ActiveRecord::Materialized::InstallHooks.install!
end

if defined?(Rails::Railtie)
  require_relative "activerecord/materialized/railtie"
end
