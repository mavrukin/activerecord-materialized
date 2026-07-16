# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Tracks every defined view class and provides bulk operations
    # (refresh / rebuild / warm-up / verify) across all of them.
    #
    # @api private
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

        def for_class_name(class_name)
          all.find { |view| view.name == class_name }
        end

        def all
          views.values
        end

        # Incremental pass over every registered view; rebuild_all! for a full one.
        def refresh_all!
          all.map(&:refresh!)
        end

        def refresh_stale!
          all.select(&:stale?).map(&:refresh!)
        end

        def rebuild_all!
          all.map { |view| view.rebuild!(confirm: true) }
        end

        def reconcile_all!(mode: :checksum, sample: nil)
          all.map { |view| reconcile_view(view, mode: mode, sample: sample) }
        end

        def reconcile_stale!(mode: :checksum, sample: nil)
          all.select(&:stale?).map { |view| reconcile_view(view, mode: mode, sample: sample) }
        end

        def warm_up_all!
          all.map(&:warm_up!)
        end

        def reset!
          @views = {}
        end

        private

        # Reconcile one view, isolating a failure so a single unhealthy view (e.g. a
        # transiently broken source relation) can't abort the scheduled backstop for
        # the rest of the fleet; the error is reported on the result, not swallowed.
        def reconcile_view(view, mode:, sample:)
          view.reconcile!(mode: mode, sample: sample)
        rescue StandardError => e
          ReconcileResult.new(view_name: view.view_key, mode: mode, repaired_keys: [], error: e.message)
        end

        def views
          @views ||= {}
        end
      end
    end
  end
end
