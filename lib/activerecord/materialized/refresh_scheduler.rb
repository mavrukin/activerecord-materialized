# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class RefreshScheduler
      class << self
        extend T::Sig

        sig { params(view_class: ViewClass).void }
        def schedule(view_class)
          view_class.mark_dependencies_changed!

          case view_class.resolved_refresh_strategy
          when :manual
            nil
          when :immediate
            view_class.refresh!
          when :async
            dispatch_async(view_class)
          else
            raise ArgumentError, "Unknown refresh strategy: #{view_class.resolved_refresh_strategy}"
          end
        end

        private

        sig { params(view_class: ViewClass).void }
        def dispatch_async(view_class)
          if use_active_job?
            T.unsafe(RefreshJob).perform_later(view_class.view_key)
          else
            AsyncRefresher.enqueue(view_class)
          end
        end

        sig { returns(T::Boolean) }
        def use_active_job?
          config = ActiveRecord::Materialized.configuration
          !!(config.refresh_dispatcher == :active_job && defined?(ActiveJob::Base))
        end
      end
    end
  end
end
