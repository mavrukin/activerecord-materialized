# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # ActiveJob wrapper that runs a view's incremental refresh on a background worker.
    class RefreshJob < ::ActiveJob::Base
      queue_as { ::ActiveRecord::Materialized.configuration.refresh_queue_name }

      def perform(view_key)
        view_class = Registry.find(view_key)
        return if view_class.nil?
        return unless view_class.dirty?

        view_class.refresh!
      end
    end
  end
end
