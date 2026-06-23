# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Dispatches a view's configured refresh strategy (`:async` / `:immediate` / `:manual`) after a write.
    #
    # @api private
    class RefreshScheduler
      class << self
        extend T::Sig

        sig { params(view_class: ViewClass).void }
        def schedule(view_class)
          # Capture the transition before marking dirty so the async dispatcher
          # can coalesce: a bulk write only needs one job for the whole burst.
          newly_dirty = !view_class.dirty?
          view_class.mark_dependencies_changed!

          case view_class.resolved_refresh_strategy
          when :manual
            nil
          when :immediate
            view_class.refresh!
          when :async
            dispatch_async(view_class, newly_dirty)
          else
            raise ArgumentError, "Unknown refresh strategy: #{view_class.resolved_refresh_strategy}"
          end
        end

        private

        sig { params(view_class: ViewClass, newly_dirty: T::Boolean).void }
        def dispatch_async(view_class, newly_dirty)
          if use_active_job?
            # ActiveJob has no enqueue-level coalescing, so only enqueue when the
            # view first goes dirty; the job drains the accumulated payload. The
            # in-process refresher already coalesces via its debounce timer.
            T.unsafe(RefreshJob).perform_later(view_class.view_key) if newly_dirty
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
