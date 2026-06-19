# frozen_string_literal: true

module ActiveRecord
  module Materialized
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

      private

      def pending
        @pending ||= {}
      end

      def mutex
        @mutex ||= Mutex.new
      end

      def schedule_unlocked(interval)
        cancel_timer_unlocked

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
        cancel_timer_unlocked

        views.each do |view_class|
          next unless view_class.dirty? || !view_class.table_exists?

          view_class.refresh!
        end
      end
    end
  end
  end
end
