# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class Configuration
      extend T::Sig

      sig { returns(String) }
      attr_accessor :metadata_table_name

      sig { returns(T.nilable(DebounceInterval)) }
      attr_accessor :default_max_staleness

      sig { returns(T.nilable(Integer)) }
      attr_accessor :refresh_timeout

      sig { returns(T::Boolean) }
      attr_accessor :atomic_swap_refresh

      sig { returns(Symbol) }
      attr_accessor :default_refresh_strategy

      sig { returns(DebounceInterval) }
      attr_accessor :default_refresh_debounce

      sig { returns(Symbol) }
      attr_accessor :refresh_dispatcher

      sig { returns(Symbol) }
      attr_accessor :refresh_queue_name

      sig { void }
      def initialize
        @metadata_table_name = T.let("ar_materialized_view_metadata", String)
        @default_max_staleness = T.let(nil, T.nilable(DebounceInterval))
        @refresh_timeout = T.let(nil, T.nilable(Integer))
        @atomic_swap_refresh = T.let(true, T::Boolean)
        @default_refresh_strategy = T.let(:async, Symbol)
        @default_refresh_debounce = T.let(2, DebounceInterval)
        @refresh_dispatcher = T.let(:async, Symbol)
        @refresh_queue_name = T.let(:materialized_views, Symbol)
      end
    end
  end
end
