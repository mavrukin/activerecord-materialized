# frozen_string_literal: true

module BenchmarkSupport
  # Captures the gem's +ActiveSupport::Notifications+ lifecycle events into an ordered
  # timeline, so a scenario can be observed — and asserted on — through the engine's
  # real signals rather than a mock. Reused by the demo (to visualize the flow as it
  # happened) and by integration tests (to assert what actually happened).
  #
  # Because read events are emitted only while a subscriber is attached, simply
  # running inside {#capture} is what makes the read path observable.
  class InstrumentationRecorder
    # Event name => the short stage label surfaced to callers.
    STAGES = {
      "read.active_record_materialized" => :read,
      "refresh.active_record_materialized" => :refresh,
      "maintenance.active_record_materialized" => :maintenance,
      "reconcile.active_record_materialized" => :reconcile
    }.freeze

    Event = Struct.new(:stage, :name, :view, :payload, :offset_ms, keyword_init: true)

    def initialize
      @events = []
      @subscribers = []
      @started_at = 0.0
    end

    attr_reader :events

    # Subscribe, run the block, always unsubscribe; returns self so the caller can
    # read the recorded #events / #for_view timeline afterwards.
    def capture
      @started_at = monotonic_ms
      subscribe
      yield
      self
    ensure
      unsubscribe
    end

    # The timeline for a single view, in the order the events fired.
    def for_view(view_class)
      @events.select { |event| event.view == view_class }
    end

    private

    def subscribe
      STAGES.each do |name, stage|
        @subscribers << ActiveSupport::Notifications.subscribe(name) do |*args|
          payload = ActiveSupport::Notifications::Event.new(*args).payload
          @events << Event.new(
            stage: stage, name: name, view: payload[:view],
            payload: payload.except(:view), offset_ms: (monotonic_ms - @started_at).round(2)
          )
        end
      end
    end

    def unsubscribe
      @subscribers.each { |subscriber| ActiveSupport::Notifications.unsubscribe(subscriber) }
      @subscribers.clear
    end

    def monotonic_ms
      Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000
    end
  end
end
