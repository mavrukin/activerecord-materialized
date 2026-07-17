# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # ActiveJob wrapper that reconciles a single view on a background worker — the
    # per-view fan-out unit for the periodic bounded-staleness backstop across a
    # fleet, mirroring {RefreshJob} for the write path.
    class ReconcileJob < ::ActiveJob::Base
      queue_as { ::ActiveRecord::Materialized.configuration.reconcile_queue_name }

      def perform(view_key, mode: :checksum, sample: nil)
        view_class = Registry.find(view_key)
        return if view_class.nil?
        # Another server in the fleet may have refreshed or reconciled it since this
        # job was enqueued; skip the redundant (expensive) verification if so.
        return unless view_class.stale?

        view_class.reconcile!(mode: mode, sample: sample)
      end
    end
  end
end
