# frozen_string_literal: true

module ActiveRecord
  module Materialized
  class Configuration
    attr_accessor :metadata_table_name,
                  :default_max_staleness,
                  :refresh_timeout,
                  :atomic_swap_refresh,
                  :default_refresh_strategy,
                  :default_refresh_debounce,
                  :refresh_dispatcher,
                  :refresh_queue_name

    def initialize
      @metadata_table_name = "ar_materialized_view_metadata"
      @default_max_staleness = nil
      @refresh_timeout = nil
      @atomic_swap_refresh = true
      @default_refresh_strategy = :async
      @default_refresh_debounce = 2
      @refresh_dispatcher = :async
      @refresh_queue_name = :materialized_views
    end

    def default_refresh_debounce=(seconds)
      @default_refresh_debounce = seconds
    end
  end
  end
end
