# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Raised when a read hits a cold view under the :raise cold-read strategy.
    class NotMaterializedError < StandardError; end

    # Read and refresh API mixed into a {View}: `rebuild!`, `refresh!`, `refresh_if_stale!`,
    # `materialized?`, `stale?`, `dirty?`, and the routed query methods.
    module ViewQueryAccessClassMethods
      def self.included(base)
        base.extend(ClassMethods)
      end

      # The read and refresh methods available on a {View} subclass.
      module ClassMethods
        def view_class
          self
        end

        # Whether the view needs refreshing — dirty, never refreshed, or past its +max_staleness+.
        #
        # @return [Boolean]
        def stale?
          view_class.metadata.stale?
        end

        # Whether dependency writes have marked the view dirty since its last refresh.
        #
        # @return [Boolean]
        def dirty?
          view_class.metadata.dirty?
        end

        # Whether the view has been fully materialized; cold views are served read-through.
        #
        # @return [Boolean]
        def warm?
          view_class.metadata.warm?
        end

        # Reads are served from the cache only once warmed and the table exists;
        # otherwise they fall through to the cold-read path.
        #
        # @return [Boolean]
        def materialized?
          view_class.table_exists? && view_class.metadata.warm?
        end

        # When the view was last refreshed, or +nil+ if it never has been.
        #
        # @return [Time, nil]
        def last_refreshed_at
          view_class.metadata.last_refreshed_at
        end

        # The oldest applied CDC source watermark across the view's partitions — its most-behind
        # partition — or +nil+ if no watermarked change has been ingested (see {SourceWatermark}).
        # Subtract from your source clock (same unit as the +source_ts+ you pass {Materialized.ingest_change})
        # to get the view's freshness/lag.
        #
        # @return [Integer, nil]
        def source_watermark
          SourceWatermark.new(view_class).oldest
        end

        # Whether a refresh is currently in progress for the view.
        #
        # @return [Boolean]
        def refreshing?
          view_class.metadata.refreshing?
        end

        def mark_dependencies_changed!
          view_class.metadata.mark_dirty!
        end

        def table_exists?
          view_class.connection.data_source_exists?(view_class.table_name)
        end

        # Incremental maintenance only — never scans all base data.
        #
        # @return [RefreshResult]
        def refresh!
          Refresher.new(view_class).refresh!
        end

        # Refreshes the view only when it is materialized and stale; otherwise a no-op.
        #
        # @return [RefreshResult, nil] the refresh result, or +nil+ when no refresh was needed
        def refresh_if_stale!
          refresh! if materialized? && stale?
        end

        # Verify this view's contents against its source and repair any drift with
        # scoped maintenance (never a full rebuild). See {Reconciler}.
        #
        # @param mode [Symbol] drift-check depth: +:row_count+, +:checksum+, or +:full+
        # @param sample [Numeric, nil] verify a random subset (Integer count / Float fraction)
        # @return [ReconcileResult]
        def reconcile!(mode: :checksum, sample: nil)
          Reconciler.new(view_class, mode: mode, sample: sample).reconcile!
        end

        # The only path that scans all base data; `confirm:` guards against
        # firing a full materialization by accident.
        #
        # @param confirm [Boolean] must be +true+ to run the full materialization
        # @raise [ArgumentError] unless +confirm+ is true
        # @return [RefreshResult]
        def rebuild!(confirm: false)
          unless confirm
            Kernel.raise ArgumentError,
                         "#{view_class.name}.rebuild! performs a full materialization; call rebuild!(confirm: true)"
          end

          Refresher.new(view_class).rebuild!
        end

        def all(*args)
          read_router.scope.all(*args)
        end

        def where(*args)
          read_router.partition_scope(args).where(*args)
        end

        def find(*args)
          read_router.scope.find(*args)
        end

        def find_by(*args)
          read_router.partition_scope(args).find_by(*args)
        end

        def count(*args)
          read_router.scope.count(*args)
        end

        private

        def read_router
          ReadRouter.new(view_class)
        end
      end
    end
  end
end
