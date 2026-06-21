# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    module ViewRefreshPolicyClassMethods
      extend T::Sig
      extend T::Helpers

      sig { params(base: T.class_of(View)).void }
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        extend T::Sig

        sig { returns(T.class_of(View)) }
        def view_class
          T.cast(self, T.class_of(View))
        end

        sig { params(strategy: Symbol).void }
        def refresh_on_change(strategy = :async)
          @refresh_strategy = T.let(strategy.to_sym, T.nilable(Symbol))
        end

        sig { params(seconds: DebounceInterval).void }
        def refresh_debounce(seconds)
          @refresh_debounce = T.let(seconds, T.nilable(DebounceInterval))
        end

        sig { params(strategy: Symbol).void }
        def cold_read(strategy)
          @cold_read_strategy = T.let(strategy.to_sym, T.nilable(Symbol))
        end

        sig { returns(Symbol) }
        def resolved_cold_read_strategy
          T.let(@cold_read_strategy, T.nilable(Symbol)) ||
            ActiveRecord::Materialized.configuration.default_cold_read_strategy
        end

        sig { returns(Symbol) }
        def resolved_refresh_strategy
          @refresh_strategy || ActiveRecord::Materialized.configuration.default_refresh_strategy
        end

        sig { returns(T.any(Integer, Float)) }
        def resolved_refresh_debounce
          interval = if @refresh_debounce.nil?
                       ActiveRecord::Materialized.configuration.default_refresh_debounce
                     else
                       @refresh_debounce
                     end
          interval.respond_to?(:to_f) ? interval.to_f : interval.to_i
        end

        sig do
          params(
            duration: T.nilable(StalenessDuration),
            block: T.nilable(T.proc.returns(StalenessDuration))
          ).void
        end
        def max_staleness(duration = nil, &block)
          @max_staleness_setting = T.let(duration || block, T.nilable(T.any(StalenessDuration, Proc)))
        end

        sig { returns(T.nilable(StalenessDuration)) }
        def resolved_max_staleness
          setting = @max_staleness_setting
          default = ActiveRecord::Materialized.configuration.default_max_staleness
          return T.cast(default, T.nilable(StalenessDuration)) if setting.nil?
          return T.unsafe(view_class).instance_eval(&setting) if setting.is_a?(Proc)

          setting
        end
      end

      mixes_in_class_methods ClassMethods
    end
  end
end
