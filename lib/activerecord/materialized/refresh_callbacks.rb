# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Adds `before_refresh` / `after_refresh` lifecycle callbacks to a {View}.
    module RefreshCallbacks
      extend T::Sig

      sig { params(base: T.class_of(View)).void }
      def self.included(base)
        base.extend(ClassMethods)
      end

      # The callback-registration methods available on a {View} subclass.
      module ClassMethods
        extend T::Sig

        sig { returns(T::Hash[Symbol, T::Array[RefreshCallbackName]]) }
        def refresh_callback_store
          @refresh_callback_store ||= T.let(
            { before_refresh: [], after_refresh: [] },
            T.nilable(T::Hash[Symbol, T::Array[RefreshCallbackName]])
          )
        end

        sig { params(methods: Symbol, block: T.nilable(T.proc.void)).void }
        def before_refresh(*methods, &block)
          register_refresh_callback(:before_refresh, methods, block)
        end

        sig { params(methods: Symbol, block: T.nilable(T.proc.void)).void }
        def after_refresh(*methods, &block)
          register_refresh_callback(:after_refresh, methods, block)
        end

        sig { params(name: Symbol).void }
        def run_refresh_callbacks(name)
          callbacks = refresh_callback_store.fetch(name, [])
          callbacks.each do |callback|
            case callback
            when Symbol
              T.unsafe(self).public_send(callback)
            when Proc
              T.unsafe(self).instance_eval(&callback)
            end
          end
        end

        private

        sig { params(name: Symbol, methods: T::Array[Symbol], block: T.nilable(T.proc.void)).void }
        def register_refresh_callback(name, methods, block)
          callbacks = T.must(refresh_callback_store[name]).dup
          methods.each { |method| callbacks << method }
          callbacks << block if block
          refresh_callback_store[name] = callbacks
        end
      end
    end
  end
end
