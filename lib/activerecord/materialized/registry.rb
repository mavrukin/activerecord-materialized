# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Tracks every defined view class and provides bulk operations
    # (refresh / rebuild / warm-up / verify) across all of them.
    #
    # @api private
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

        sig { params(class_name: String).returns(T.nilable(ViewClass)) }
        def for_class_name(class_name)
          all.find { |view| view.name == class_name }
        end

        sig { returns(T::Array[ViewClass]) }
        def all
          views.values
        end

        # Incremental pass over every registered view; rebuild_all! for a full one.
        sig { returns(T::Array[RefreshResult]) }
        def refresh_all!
          all.map(&:refresh!)
        end

        sig { returns(T::Array[RefreshResult]) }
        def refresh_stale!
          all.select(&:stale?).map(&:refresh!)
        end

        sig { returns(T::Array[RefreshResult]) }
        def rebuild_all!
          all.map { |view| view.rebuild!(confirm: true) }
        end

        sig { params(mode: Symbol, sample: T.nilable(Numeric)).returns(T::Array[ReconcileResult]) }
        def reconcile_all!(mode: :checksum, sample: nil)
          all.map { |view| reconcile_view(view, mode: mode, sample: sample) }
        end

        sig { params(mode: Symbol, sample: T.nilable(Numeric)).returns(T::Array[ReconcileResult]) }
        def reconcile_stale!(mode: :checksum, sample: nil)
          all.select(&:stale?).map { |view| reconcile_view(view, mode: mode, sample: sample) }
        end

        sig { returns(T::Array[T.nilable(RefreshResult)]) }
        def warm_up_all!
          all.map(&:warm_up!)
        end

        sig { void }
        def reset!
          @views = {}
        end

        private

        # Reconcile one view, isolating a failure so a single unhealthy view (e.g. a
        # transiently broken source relation) can't abort the scheduled backstop for
        # the rest of the fleet; the error is reported on the result, not swallowed.
        sig { params(view: ViewClass, mode: Symbol, sample: T.nilable(Numeric)).returns(ReconcileResult) }
        def reconcile_view(view, mode:, sample:)
          view.reconcile!(mode: mode, sample: sample)
        rescue StandardError => e
          ReconcileResult.new(view_name: view.view_key, mode: mode, repaired_keys: [], error: e.message)
        end

        sig { returns(T::Hash[String, ViewClass]) }
        def views
          @views ||= T.let({}, T.nilable(T::Hash[String, ViewClass]))
        end
      end
    end
  end
end
