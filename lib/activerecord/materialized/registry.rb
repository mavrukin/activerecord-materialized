# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class Registry
      class << self
        extend T::Sig

        sig { params(view_class: ViewClass).void }
        def register(view_class)
          views[view_class.view_key] = view_class
        end

        sig { params(view_class: ViewClass).void }
        def unregister(view_class)
          views.delete(view_class.view_key)
        end

        sig { params(key: T.any(String, Symbol)).returns(T.nilable(ViewClass)) }
        def find(key)
          views[key.to_s]
        end

        sig { returns(T::Array[ViewClass]) }
        def all
          views.values
        end

        sig { params(options: T.untyped).returns(T::Array[T.untyped]) }
        def refresh_all!(**options)
          all.map { |view| view.refresh!(**options) }
        end

        sig { params(options: T.untyped).returns(T::Array[T.untyped]) }
        def refresh_stale!(**options)
          all.select(&:stale?).each { |view| view.refresh!(**options) }
        end

        sig { void }
        def reset!
          @views = {}
        end

        private

        sig { returns(T::Hash[String, ViewClass]) }
        def views
          @views ||= T.let({}, T.nilable(T::Hash[String, ViewClass]))
        end
      end
    end
  end
end
