# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # In-process, debounced background refresher — the default `:async` dispatcher.
    #
    # @api private
    class AsyncRefresher
      class << self
        def enqueue(view_class)
          interval = view_class.resolved_refresh_debounce

          mutex.synchronize do
            pending[view_class.view_key] = view_class
            schedule_unlocked(interval)
          end
        end

        def flush!
          mutex.synchronize do
            cancel_timer_unlocked
            drain_pending_unlocked
          end
        end

        def pending_count
          mutex.synchronize { pending.size }
        end

        def reset!
          mutex.synchronize do
            cancel_timer_unlocked
            pending.clear
          end
        end

        # When paused, refreshes accumulate and run only on an explicit flush! —
        # no background timer fires.
        attr_writer :paused

        def paused?
          @paused || false
        end

        private

        def pending
          @pending ||= {}
        end

        def mutex
          @mutex ||= Mutex.new
        end

        def schedule_unlocked(interval)
          cancel_timer_unlocked
          return if paused?

          @timer_thread = Thread.new do
            sleep(interval) unless interval.zero?
            mutex.synchronize { drain_pending_unlocked }
          end
        end

        def cancel_timer_unlocked
          return unless @timer_thread&.alive?

          @timer_thread.kill
          @timer_thread = nil
        end

        def drain_pending_unlocked
          views = pending.values
          pending.clear

          views.each do |view_class|
            next unless view_class.dirty?

            view_class.refresh!
          end
        end
      end
    end
  end
end
