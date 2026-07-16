# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Adds `before_refresh` / `after_refresh` lifecycle callbacks to a {View}.
    module RefreshCallbacks
      def self.included(base)
        base.extend(ClassMethods)
      end

      # The callback-registration methods available on a {View} subclass.
      module ClassMethods
        def refresh_callback_store
          @refresh_callback_store ||= { before_refresh: [], after_refresh: [] }
        end

        def before_refresh(*methods, &block)
          register_refresh_callback(:before_refresh, methods, block)
        end

        def after_refresh(*methods, &block)
          register_refresh_callback(:after_refresh, methods, block)
        end

        def run_refresh_callbacks(name)
          callbacks = refresh_callback_store.fetch(name, [])
          callbacks.each do |callback|
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
          callbacks = refresh_callback_store[name].dup
          methods.each { |method| callbacks << method }
          callbacks << block if block
          refresh_callback_store[name] = callbacks
        end
      end
    end
  end
end
