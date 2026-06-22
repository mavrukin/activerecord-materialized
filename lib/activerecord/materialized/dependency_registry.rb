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
            subscribe_source_table!(table)
          end
        end

        sig { params(table: String).returns(T::Array[ViewClass]) }
        def views_for_table(table)
          T.must(dependency_index[normalize_table(table)])
        end

        sig { params(change: WriteChange).void }
        def publish_write_change!(change)
          affected_views([change.table_name]).each do |view|
            view.record_write_change!(change)
            RefreshScheduler.schedule(view)
          end
        end

        sig { params(tables: T::Array[String]).void }
        def mark_dirty_for_tables!(tables)
          affected_views(tables).each(&:mark_dependencies_changed!)
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

        sig { params(table: String).void }
        def subscribe_source_table!(table)
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
