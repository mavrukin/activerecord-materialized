# frozen_string_literal: true

module ActiveRecord
  module Materialized
  class Registry
    class << self
      def register(view_class)
        views[view_class.view_key] = view_class
      end

      def unregister(view_class)
        views.delete(view_class.view_key)
      end

      def find(key)
        views[key.to_s]
      end

      def all
        views.values
      end

      def refresh_all!(**options)
        all.map { |view| view.refresh!(**options) }
      end

      def refresh_stale!(**options)
        all.select(&:stale?).each { |view| view.refresh!(**options) }
      end

      private

      def views
        @views ||= {}
      end

      def reset!
        @views = {}
      end
    end
  end
  end
end
