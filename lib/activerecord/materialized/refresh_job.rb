# frozen_string_literal: true

module ActiveRecord
  module Materialized
  class RefreshJob < ActiveJob::Base
    queue_as { ActiveRecord::Materialized.configuration.refresh_queue_name }

    def perform(view_class_name)
      view_class = view_class_name.constantize
      return unless view_class < ActiveRecord::Materialized::View
      return unless view_class.dirty? || !view_class.table_exists?

      view_class.refresh!
    end
  end
  end
end
