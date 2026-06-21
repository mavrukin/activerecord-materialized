# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class RefreshJob < ::ActiveJob::Base
      extend T::Sig

      queue_as { ::ActiveRecord::Materialized.configuration.refresh_queue_name }

      sig { params(view_key: String).void }
      def perform(view_key)
        view_class = Registry.find(view_key)
        return if view_class.nil?
        return unless view_class.dirty?

        # Incremental maintenance only; never builds a cold view.
        view_class.refresh!
      end
    end
  end
end
