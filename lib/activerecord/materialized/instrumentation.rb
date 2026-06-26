# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Emits `ActiveSupport::Notifications` events at the read / refresh /
    # maintenance lifecycle points so adopters can wire freshness and behavior
    # SLIs to any APM / StatsD / OpenTelemetry backend without the gem taking a
    # dependency on a specific telemetry vendor.
    #
    # The event names and payload keys documented here are a stable contract —
    # subscribe with {https://api.rubyonrails.org/classes/ActiveSupport/Notifications.html
    # ActiveSupport::Notifications}:
    #
    #   ActiveSupport::Notifications.subscribe("read.active_record_materialized") do |event|
    #     StatsD.increment("mv.read.#{event.payload[:source]}", tags: ["view:#{event.payload[:view]}"])
    #   end
    #
    # Events:
    #
    # * +read.active_record_materialized+ — one per routed read. Payload:
    #   +:view+ (the view class), +:source+ (+:cache+, +:read_through+,
    #   +:serve_stale+, or +:raise+), +:staleness+ (seconds since the last
    #   successful refresh, or +nil+ when never refreshed).
    # * +refresh.active_record_materialized+ — one per +refresh!+/+rebuild!+,
    #   timed. Payload: +:view+, +:operation+ (+:incremental+ or +:rebuild+),
    #   +:mode+ (+:summary_delta+, +:scoped_recompute+, or +:full+),
    #   +:partition_count+ (partitions recomputed, or +nil+ for a full pass),
    #   +:row_count+, +:skipped+, and — on failure — the standard
    #   +:exception+/+:exception_object+ keys set by +ActiveSupport::Notifications+.
    # * +maintenance.active_record_materialized+ — one per dependency write that
    #   records pending maintenance. Payload: +:view+, +:table+, +:operation+
    #   (+:create+/+:update+/+:destroy+), +:path+ (+:summary_delta+ or
    #   +:scoped_recompute+), +:scope+ (+:scoped+, or +:full+ when the write
    #   widened to a full recompute because its partition key could not be
    #   derived), +:partition_count+ (distinct partitions scoped, 0 on widen).
    module Instrumentation
      extend T::Sig

      READ = T.let("read.active_record_materialized", String)
      REFRESH = T.let("refresh.active_record_materialized", String)
      MAINTENANCE = T.let("maintenance.active_record_materialized", String)

      class << self
        extend T::Sig

        # Fired once per routed read. The staleness lookup costs a metadata read,
        # so it is skipped entirely unless a subscriber is attached.
        sig { params(view_class: ViewClass, source: Symbol).void }
        def read(view_class, source:)
          return unless ::ActiveSupport::Notifications.notifier.listening?(READ)

          ::ActiveSupport::Notifications.instrument(
            READ,
            view: view_class, source: source, staleness: staleness_for(view_class)
          )
        end

        # Wraps a refresh/rebuild so the event carries its wall-clock duration and
        # any raised exception. The block runs the refresh and returns its
        # {RefreshResult}; the row count and skipped flag are read back from it,
        # while the block annotates the payload with the +:mode+ and
        # +:partition_count+ it can only know mid-flight.
        sig do
          params(
            view_class: ViewClass,
            operation: Symbol,
            block: T.proc.params(payload: T::Hash[Symbol, T.untyped]).returns(RefreshResult)
          ).returns(RefreshResult)
        end
        def refresh(view_class, operation:, &block)
          ::ActiveSupport::Notifications.instrument(REFRESH, view: view_class, operation: operation) do |payload|
            result = yield(payload)
            payload[:row_count] = result.row_count
            payload[:skipped] = result.skipped
            result
          end
        end

        # Fired once per dependency write that records pending maintenance.
        sig do
          params(
            view_class: ViewClass, change: WriteChange, path: Symbol, scope: Symbol, partition_count: Integer
          ).void
        end
        def maintenance(view_class, change:, path:, scope:, partition_count:)
          ::ActiveSupport::Notifications.instrument(
            MAINTENANCE,
            view: view_class, table: change.table_name, operation: change.operation.to_sym,
            path: path, scope: scope, partition_count: partition_count
          )
        end

        private

        sig { params(view_class: ViewClass).returns(T.nilable(Float)) }
        def staleness_for(view_class)
          last_refreshed_at = view_class.metadata.last_refreshed_at
          return nil if last_refreshed_at.nil?

          (Metadata::Timestamps.current.to_time - last_refreshed_at.to_time).to_f
        end
      end
    end
  end
end
