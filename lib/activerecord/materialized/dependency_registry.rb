# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class DependencyRegistry
      class << self
        extend T::Sig

        sig { params(view_class: ViewClass, tables: T.any(Symbol, String, T::Array[T.any(Symbol, String)])).void }
        def register(view_class, tables)
          normalized = Array(tables).map { |table| normalize_table(table) }
          T.unsafe(view_class).instance_variable_set(:@dependency_tables, normalized)

          normalized.each do |table|
            bucket = T.cast(dependency_index[table], T::Array[ViewClass])
            bucket << view_class unless bucket.include?(view_class)
          end
        end

        sig { params(table: String).returns(T::Array[ViewClass]) }
        def views_for_table(table)
          T.must(dependency_index[normalize_table(table)])
        end

        sig { params(tables: T::Array[String]).void }
        def schedule_refresh_for_tables!(tables)
          affected_views(tables).each { |view| RefreshScheduler.schedule(view) }
        end

        sig { params(tables: T::Array[String]).void }
        def mark_dirty_for_tables!(tables)
          affected_views(tables).each(&:mark_dependencies_changed!)
        end

        sig { void }
        def reset!
          @dependency_index = Hash.new { |hash, key| hash[key] = [] }
          @recorders = {}
        end

        sig { params(connection: Connection).returns(TransactionRefreshRecorder) }
        def recorder_for(connection)
          recorders[connection.object_id] ||= TransactionRefreshRecorder.new.tap do |recorder|
            recorder.bind_connection!(connection)
          end
        end

        sig { params(connection: Connection).void }
        def clear_recorder(connection)
          recorders.delete(connection.object_id)
        end

        private

        sig { returns(T::Hash[Integer, TransactionRefreshRecorder]) }
        def recorders
          @recorders ||= T.let({}, T.nilable(T::Hash[Integer, TransactionRefreshRecorder]))
        end

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
