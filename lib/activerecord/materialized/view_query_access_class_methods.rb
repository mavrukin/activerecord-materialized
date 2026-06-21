# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Raised when a read hits a cold view under the :raise cold-read strategy.
    class NotMaterializedError < StandardError; end

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

        sig { returns(T::Boolean) }
        def warm?
          view_class.metadata.warm?
        end

        # A view is materialized once it has been explicitly rebuilt/warmed and
        # its cache table exists. Only then are reads served from the cache;
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

        # Incremental maintenance only — never builds a cold view or scans all
        # base data. Safe to call from reads and background workers.
        sig { returns(RefreshResult) }
        def refresh!
          Refresher.new(view_class).refresh!
        end

        sig { returns(T.nilable(RefreshResult)) }
        def refresh_if_stale!
          refresh! if materialized? && stale?
        end

        # Explicit, intentional full materialization — the only path that scans
        # all base data. Guarded by `confirm:` so it is never fired by accident.
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
          read_scope.all(*args)
        end

        sig { params(args: T.untyped).returns(T.untyped) }
        def where(*args)
          partition_scope(args).where(*args)
        end

        sig { params(args: T.untyped).returns(T.untyped) }
        def find(*args)
          read_scope.find(*args)
        end

        sig { params(args: T.untyped).returns(T.untyped) }
        def find_by(*args)
          partition_scope(args).find_by(*args)
        end

        sig { params(args: T.untyped).returns(T.untyped) }
        def count(*args)
          read_scope.count(*args)
        end

        private

        # The relation reads are served from: the cache table when the view is
        # materialized, otherwise the cold-read path (see ColdRead).
        sig { returns(T.untyped) }
        def read_scope
          materialized? ? cache_scope : cold_scope
        end

        # Per-partition fast path for keyed reads. On a cold view whose touched
        # partitions are all already materialized, serve from the cache;
        # otherwise read through and enqueue maintenance so the partitions become
        # fast on the next read (the populate-on-read behavior).
        sig { params(args: T::Array[T.untyped]).returns(T.untyped) }
        def partition_scope(args)
          return cache_scope if materialized?

          keys = PartitionState.keys_from(view_class, args)
          return cold_scope if keys.nil?
          return cache_scope if PartitionState.new(view_class).all_fresh?(keys)

          enqueue_partition_maintenance(keys)
          cold_scope
        end

        sig { returns(T.untyped) }
        def cache_scope
          T.unsafe(view_class).unscoped
        end

        sig { returns(T.untyped) }
        def cold_scope
          ColdRead.new(view_class).scope
        end

        sig { params(keys: T::Array[T.untyped]).void }
        def enqueue_partition_maintenance(keys)
          MaintenanceStore.new(view_class).merge!(MaintenanceDelta.scoped(keys))
          RefreshScheduler.schedule(view_class)
        end
      end

      mixes_in_class_methods ClassMethods
    end
  end
end
