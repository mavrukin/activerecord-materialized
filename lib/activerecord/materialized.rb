# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "active_record"
require "active_support/concern"
require "active_support/core_ext/string/inflections"
require "active_support/core_ext/module/delegation"
require "active_support/core_ext/integer/time"
require "active_support/core_ext/object/blank"
require "securerandom"

require_relative "../activerecord_materialized_types"
require_relative "materialized/type_reexports"
require_relative "materialized/configuration"
require_relative "materialized/module_api"
require_relative "materialized/refresh_callbacks"
require_relative "materialized/dependency_registry"
require_relative "materialized/transaction_refresh_recorder"
require_relative "materialized/async_refresher"
require_relative "materialized/refresh_scheduler"
require_relative "materialized/registry"
require_relative "materialized/metadata_record"
require_relative "materialized/view_source_definition"
require_relative "materialized/view_configuration_class_methods"
require_relative "materialized/view_query_access_class_methods"
require_relative "materialized/view"
require_relative "materialized/view_class"
require_relative "materialized/refresh_result"
require_relative "materialized/refresher"
require_relative "materialized/metadata"
require_relative "materialized/change_subscriber"
require_relative "materialized/install_hooks"

require_relative "materialized/refresh_job" if defined?(ActiveJob::Base)

ActiveSupport.on_load(:active_record) do
  ActiveRecord::Materialized::InstallHooks.install!
end

ActiveRecord::Materialized::InstallHooks.install! if defined?(ActiveRecord::Base)

require_relative "activerecord/materialized/railtie" if defined?(Rails::Railtie)
