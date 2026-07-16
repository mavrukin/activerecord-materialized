# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Maps dependency tables to the views that depend on them and publishes committed writes to them.
    #
    # @api private
    class DependencyRegistry
      class << self
        def register(view_class, tables)
          normalized = Array(tables).flat_map { |entry| normalize_dependency(entry) }
          view_class.instance_variable_set(:@dependency_tables, normalized)

          normalized.each do |table|
            bucket = dependency_index[table]
            bucket << view_class unless bucket.include?(view_class)
            subscribe_source_table!(table, view_class)
          end
        end

        def views_for_table(table)
          dependency_index[normalize_table(table)]
        end

        # Records a committed write and schedules refresh for the affected views.
        # `source` identifies the publisher so no view is maintained by two sources:
        # a callback publish (`:callbacks`) drives only callback-backed views, and an
        # explicit ingestion-API publish (`nil`) drives only externally-fed views.
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
        def mark_dirty_for_tables!(tables)
          affected_views(tables).each do |view|
            MaintenanceStore.new(view).merge!(MaintenanceDelta.full_partition)
            RefreshScheduler.schedule(view)
          end
        end

        # (Re)installs the built-in callback tracker for a view's already-declared
        # dependency tables. Invoked by `change_source :callbacks` so opting in works
        # whether it precedes or follows `depends_on`.
        def install_callbacks_for(view_class)
          view_class.dependency_tables.each { |table| subscribe_source_table!(table, view_class) }
        end

        def reset!
          @dependency_index = Hash.new { |hash, key| hash[key] = [] }
          ActiveRecord::Materialized::DependencyTrackable.reset!
        end

        private

        def dependency_index
          @dependency_index ||= Hash.new { |hash, key| hash[key] = [] }
        end

        # A callback publish reaches callback-backed views; any other (external)
        # publish reaches views that are NOT callback-backed. This keeps each view
        # tied to a single source, so the additive summary-delta path is never
        # applied twice for one write.
        def delivers_to?(view, source)
          callback_backed = view.resolved_change_source == ChangeSource::CALLBACKS
          source == ChangeSource::CALLBACKS ? callback_backed : !callback_backed
        end

        def affected_views(tables)
          Array(tables).flat_map do |table|
            next [] if skip_table?(table)

            views_for_table(table)
          end.uniq
        end

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
        def subscribe_source_table!(table, view_class)
          return unless view_class.resolved_change_source == ChangeSource::CALLBACKS

          model = TableModelRegistry.resolve(table)
          ActiveRecord::Materialized::DependencyTrackable.subscribe(model) if model
        end

        def normalize_table(table)
          ::ActiveSupport::Inflector.underscore(table.to_s.delete_prefix(":"))
        end

        def skip_table?(table)
          name = normalize_table(table)
          name.start_with?("mv_") || name == ::ActiveRecord::Materialized.metadata_table_name
        end
      end
    end
  end
end
