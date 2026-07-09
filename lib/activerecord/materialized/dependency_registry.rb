# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Maps dependency tables to the views that depend on them and publishes committed writes to them.
    #
    # @api private
    class DependencyRegistry
      class << self
        extend T::Sig

        sig do
          params(
            view_class: ViewClass,
            tables: T.any(
              Symbol,
              String,
              T.class_of(::ActiveRecord::Base),
              T::Array[T.any(Symbol, String, T.class_of(::ActiveRecord::Base))]
            )
          ).void
        end
        def register(view_class, tables)
          normalized = Array(tables).flat_map { |entry| normalize_dependency(entry) }
          T.unsafe(view_class).instance_variable_set(:@dependency_tables, normalized)

          normalized.each do |table|
            bucket = T.cast(dependency_index[table], T::Array[ViewClass])
            bucket << view_class unless bucket.include?(view_class)
            subscribe_source_table!(table, view_class)
          end
        end

        sig { params(table: String).returns(T::Array[ViewClass]) }
        def views_for_table(table)
          T.must(dependency_index[normalize_table(table)])
        end

        # Records a committed write and schedules refresh for the affected views.
        # `source` identifies the publisher so no view is maintained by two sources:
        # a callback publish (`:callbacks`) drives only callback-backed views, and an
        # explicit ingestion-API publish (`nil`) drives only externally-fed views.
        sig { params(change: WriteChange, source: T.nilable(Symbol)).void }
        def publish_write_change!(change, source: nil)
          affected_views([change.table_name]).each do |view|
            next unless delivers_to?(view, source)

            view.record_write_change!(change)
            RefreshScheduler.schedule(view)
          end
        end

        # Coarse ingestion signal: something changed in these tables but the caller
        # cannot describe the individual write. Enqueues a full recompute (the only
        # correct scope without a partition key) and schedules it — idempotent, so
        # safe to call repeatedly and after callback-skipping bulk loads.
        sig { params(tables: T::Array[String]).void }
        def mark_dirty_for_tables!(tables)
          affected_views(tables).each do |view|
            MaintenanceStore.new(view).merge!(MaintenanceDelta.full_partition)
            RefreshScheduler.schedule(view)
          end
        end

        # (Re)installs the built-in callback tracker for a view's already-declared
        # dependency tables. Invoked by `change_source :callbacks` so opting in works
        # whether it precedes or follows `depends_on`.
        sig { params(view_class: ViewClass).void }
        def install_callbacks_for(view_class)
          view_class.dependency_tables.each { |table| subscribe_source_table!(table, view_class) }
        end

        sig { void }
        def reset!
          @dependency_index = Hash.new { |hash, key| hash[key] = [] }
          ActiveRecord::Materialized::DependencyTrackable.reset!
        end

        private

        sig { returns(T::Hash[String, T::Array[ViewClass]]) }
        def dependency_index
          @dependency_index ||= T.let(
            Hash.new { |hash, key| hash[key] = [] },
            T.nilable(T::Hash[String, T::Array[ViewClass]])
          )
        end

        # A callback publish reaches callback-backed views; any other (external)
        # publish reaches views that are NOT callback-backed. This keeps each view
        # tied to a single source, so the additive summary-delta path is never
        # applied twice for one write.
        sig { params(view: ViewClass, source: T.nilable(Symbol)).returns(T::Boolean) }
        def delivers_to?(view, source)
          callback_backed = view.resolved_change_source == ChangeSource::CALLBACKS
          source == ChangeSource::CALLBACKS ? callback_backed : !callback_backed
        end

        sig { params(tables: T::Array[String]).returns(T::Array[ViewClass]) }
        def affected_views(tables)
          Array(tables).flat_map do |table|
            next [] if skip_table?(table)

            views_for_table(table)
          end.uniq
        end

        sig { params(entry: T.untyped).returns(T::Array[String]) }
        def normalize_dependency(entry)
          if entry.is_a?(Class) && entry < ::ActiveRecord::Base
            TableModelRegistry.register(entry)
            return [entry.table_name]
          end

          [normalize_table(entry)]
        end

        # Installs the built-in commit-callback tracker for a table's model, unless
        # the view opts out of callbacks (`change_source :none` / a `:none` global
        # default) — in which case the dependency is still indexed for scoping and
        # metadata, but its writes are expected to arrive via the ingestion API.
        sig { params(table: String, view_class: ViewClass).void }
        def subscribe_source_table!(table, view_class)
          return unless view_class.resolved_change_source == ChangeSource::CALLBACKS

          model = TableModelRegistry.resolve(table)
          ActiveRecord::Materialized::DependencyTrackable.subscribe(model) if model
        end

        sig { params(table: T.any(Symbol, String)).returns(String) }
        def normalize_table(table)
          ::ActiveSupport::Inflector.underscore(table.to_s.delete_prefix(":"))
        end

        sig { params(table: T.any(Symbol, String)).returns(T::Boolean) }
        def skip_table?(table)
          name = normalize_table(table)
          name.start_with?("mv_") || name == ::ActiveRecord::Materialized.metadata_table_name
        end
      end
    end
  end
end
