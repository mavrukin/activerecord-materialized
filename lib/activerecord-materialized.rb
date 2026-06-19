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

require_relative "activerecord_materialized_types"
require_relative "activerecord/materialized/type_reexports"
require_relative "activerecord/materialized/configuration"
require_relative "activerecord/materialized/module_api"
require_relative "activerecord/materialized/refresh_callbacks"
require_relative "activerecord/materialized/dependency_registry"
require_relative "activerecord/materialized/transaction_refresh_recorder"
require_relative "activerecord/materialized/async_refresher"
require_relative "activerecord/materialized/refresh_scheduler"
require_relative "activerecord/materialized/registry"
require_relative "activerecord/materialized/metadata_record"
require_relative "activerecord/materialized/view"
require_relative "activerecord/materialized/view_class"
require_relative "activerecord/materialized/refresh_result"
require_relative "activerecord/materialized/refresher"
require_relative "activerecord/materialized/maintenance_delta"
require_relative "activerecord/materialized/view_definition"
require_relative "activerecord/materialized/change_key_extractor"
require_relative "activerecord/materialized/maintenance_store"
require_relative "activerecord/materialized/incremental_maintainer"
require_relative "activerecord/materialized/metadata"
require_relative "activerecord/materialized/change_subscriber"
require_relative "activerecord/materialized/install_hooks"

require_relative "activerecord/materialized/refresh_job" if defined?(ActiveJob::Base)

ActiveSupport.on_load(:active_record) do
  ActiveRecord::Materialized::InstallHooks.install!
end

ActiveRecord::Materialized::InstallHooks.install! if defined?(ActiveRecord::Base)

require_relative "activerecord/materialized/railtie" if defined?(Rails::Railtie)
