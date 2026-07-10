# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Raised when a read hits a cold view under the :raise cold-read strategy.
    class NotMaterializedError < StandardError; end

    # Read and refresh API mixed into a {View}: `rebuild!`, `refresh!`, `refresh_if_stale!`,
    # `materialized?`, `stale?`, `dirty?`, and the routed query methods.
    module ViewQueryAccessClassMethods
      extend T::Sig
      extend T::Helpers

      sig { params(base: T.class_of(View)).void }
      def self.included(base)
        base.extend(ClassMethods)
      end

      # The read and refresh methods available on a {View} subclass.
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

        sig { returns(T::Boolean) }
        def warm?
          view_class.metadata.warm?
        end

        # Reads are served from the cache only once warmed and the table exists;
        # otherwise they fall through to the cold-read path.
        sig { returns(T::Boolean) }
        def materialized?
          view_class.table_exists? && view_class.metadata.warm?
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
        def table_exists?
          view_class.connection.data_source_exists?(view_class.table_name)
        end

        # Incremental maintenance only — never scans all base data.
        sig { returns(RefreshResult) }
        def refresh!
          Refresher.new(view_class).refresh!
        end

        sig { returns(T.nilable(RefreshResult)) }
        def refresh_if_stale!
          refresh! if materialized? && stale?
        end

        # Verify this view's contents against its source and repair any drift with
        # scoped maintenance (never a full rebuild). See {Reconciler}.
        sig { params(mode: Symbol, sample: T.nilable(Numeric)).returns(ReconcileResult) }
        def reconcile!(mode: :checksum, sample: nil)
          Reconciler.new(view_class, mode: mode, sample: sample).reconcile!
        end

        # The only path that scans all base data; `confirm:` guards against
        # firing a full materialization by accident.
        sig { params(confirm: T::Boolean).returns(RefreshResult) }
        def rebuild!(confirm: false)
          unless confirm
            Kernel.raise ArgumentError,
                         "#{view_class.name}.rebuild! performs a full materialization; call rebuild!(confirm: true)"
          end

          Refresher.new(view_class).rebuild!
        end

        sig { params(args: T.untyped).returns(T.untyped) }
        def all(*args)
          read_router.scope.all(*args)
        end

        sig { params(args: T.untyped).returns(T.untyped) }
        def where(*args)
          read_router.partition_scope(args).where(*args)
        end

        sig { params(args: T.untyped).returns(T.untyped) }
        def find(*args)
          read_router.scope.find(*args)
        end

        sig { params(args: T.untyped).returns(T.untyped) }
        def find_by(*args)
          read_router.partition_scope(args).find_by(*args)
        end

        sig { params(args: T.untyped).returns(T.untyped) }
        def count(*args)
          read_router.scope.count(*args)
        end

        private

        sig { returns(ReadRouter) }
        def read_router
          ReadRouter.new(view_class)
        end
      end

      mixes_in_class_methods ClassMethods
    end
  end
end
