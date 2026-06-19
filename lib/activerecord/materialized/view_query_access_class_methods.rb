# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    module ViewQueryAccessClassMethods
      extend T::Sig
      extend T::Helpers

      sig { params(base: T.class_of(View)).void }
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        extend T::Sig

        sig { returns(T.class_of(View)) }
        def view_class
          T.cast(self, T.class_of(View))
        end

        sig { returns(T::Boolean) }
        def stale?
          view_class.metadata.stale?
        end

        sig { returns(T::Boolean) }
        def dirty?
          view_class.metadata.dirty?
        end

        sig { returns(T.nilable(Timestamp)) }
        def last_refreshed_at
          view_class.metadata.last_refreshed_at
        end

        sig { returns(T::Boolean) }
        def refreshing?
          view_class.metadata.refreshing?
        end

        sig { void }
        def mark_dependencies_changed!
          view_class.metadata.mark_dirty!
        end

        sig { returns(T::Boolean) }
        def needs_refresh?
          klass = view_class
          return true unless klass.table_exists?
          return true if klass.metadata.last_refreshed_at.nil?
          return true if klass.metadata.dirty?

          max_staleness = klass.resolved_max_staleness
          return false if max_staleness.nil?

          klass.metadata.stale?(max_staleness: max_staleness)
        end

        sig { params(force: T::Boolean).returns(RefreshResult) }
        def refresh!(force: false)
          Thread.current[:ar_materialized_refreshing] = true
          Refresher.new(view_class).refresh!(force: force)
        ensure
          Thread.current[:ar_materialized_refreshing] = false
        end

        sig { params(force: T::Boolean).returns(T.nilable(RefreshResult)) }
        def refresh_if_stale!(force: false)
          refresh!(force: force) if needs_refresh?
        end

        sig { returns(T::Boolean) }
        def table_exists?
          view_class.connection.data_source_exists?(view_class.table_name)
        end

        sig { params(args: T.untyped).returns(T.untyped) }
        def all(*args)
          ensure_materialized!
          super
        end

        sig { params(args: T.untyped).returns(T.untyped) }
        def where(*args)
          ensure_materialized!
          super
        end

        sig { params(args: T.untyped).returns(T.untyped) }
        def find(*args)
          ensure_materialized!
          super
        end

        sig { params(args: T.untyped).returns(T.untyped) }
        def find_by(*args)
          ensure_materialized!
          super
        end

        sig { params(args: T.untyped).returns(T.untyped) }
        def count(*args)
          ensure_materialized!
          super
        end

        private

        sig { void }
        def ensure_materialized!
          klass = view_class
          return if klass.table_exists?
          return if Thread.current[:ar_materialized_refreshing]

          klass.refresh!
        end
      end

      mixes_in_class_methods ClassMethods
    end
  end
end
