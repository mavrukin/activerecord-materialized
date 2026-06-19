# frozen_string_literal: true

module ActiveRecord
  module Materialized
  module RefreshCallbacks
    extend ActiveSupport::Concern

    included do
      class_attribute :_refresh_callbacks, instance_accessor: false, default: { before_refresh: [], after_refresh: [] }
    end

    class_methods do
      def before_refresh(*methods, &block)
        register_refresh_callback(:before_refresh, methods, block)
      end

      def after_refresh(*methods, &block)
        register_refresh_callback(:after_refresh, methods, block)
      end

      def run_refresh_callbacks(name)
        Array(_refresh_callbacks[name]).each do |callback|
          case callback
          when Symbol
            public_send(callback)
          when Proc
            instance_eval(&callback)
          end
        end
      end

      private

      def register_refresh_callback(name, methods, block)
        callbacks = _refresh_callbacks[name].dup
        methods.each { |method| callbacks << method }
        callbacks << block if block
        self._refresh_callbacks = _refresh_callbacks.merge(name => callbacks)
      end
    end
  end
  end
end
