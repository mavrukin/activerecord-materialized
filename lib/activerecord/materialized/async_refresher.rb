# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class AsyncRefresher
      class << self
        extend T::Sig

        sig { params(view_class: ViewClass).void }
        def enqueue(view_class)
          interval = view_class.resolved_refresh_debounce

          mutex.synchronize do
            pending[view_class.view_key] = view_class
            schedule_unlocked(interval)
          end
        end

        sig { void }
        def flush!
          mutex.synchronize do
            cancel_timer_unlocked
            drain_pending_unlocked
          end
        end

        sig { returns(Integer) }
        def pending_count
          mutex.synchronize { pending.size }
        end

        sig { void }
        def reset!
          mutex.synchronize do
            cancel_timer_unlocked
            pending.clear
          end
        end

        # When paused, refreshes accumulate and run only on an explicit flush! —
        # no background timer fires.
        sig { params(value: T::Boolean).void }
        def paused=(value)
          @paused = T.let(value, T.nilable(T::Boolean))
        end

        sig { returns(T::Boolean) }
        def paused?
          @paused = T.let(@paused, T.nilable(T::Boolean))
          @paused || false
        end

        private

        sig { returns(T::Hash[String, ViewClass]) }
        def pending
          @pending ||= T.let({}, T.nilable(T::Hash[String, ViewClass]))
        end

        sig { returns(Mutex) }
        def mutex
          @mutex ||= T.let(Mutex.new, T.nilable(Mutex))
        end

        sig { params(interval: T.any(Integer, Float)).void }
        def schedule_unlocked(interval)
          cancel_timer_unlocked
          return if paused?

          @timer_thread = T.let(
            Thread.new do
              sleep(interval) unless interval.zero?
              mutex.synchronize { drain_pending_unlocked }
            end,
            T.nilable(Thread)
          )
        end

        sig { void }
        def cancel_timer_unlocked
          return unless @timer_thread&.alive?

          @timer_thread.kill
          @timer_thread = nil
        end

        sig { void }
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
