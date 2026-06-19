# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class View < ::ActiveRecord::Base
      extend T::Sig
      include RefreshCallbacks

      self.abstract_class = true

      class << self
        extend T::Sig

        @source_definition = T.let(nil, T.nilable(SourceDefinition))
        @max_staleness_setting = T.let(nil, T.nilable(T.any(StalenessDuration, Proc)))
        @dependency_tables = T.let(nil, T.nilable(T::Array[String]))
        @refresh_strategy = T.let(nil, T.nilable(Symbol))
        @refresh_debounce = T.let(nil, T.nilable(DebounceInterval))
        @refresh_mode = T.let(nil, T.nilable(RefreshMode))
        @incremental_source_definition = T.let(nil, T.nilable(SourceDefinition))
        @incremental_key_columns = T.let(nil, T.nilable(T::Array[String]))
        @table_name = T.let(nil, T.nilable(String))

        sig { returns(T.nilable(SourceDefinition)) }
        attr_reader :source_definition

        sig { returns(T.nilable(T.any(StalenessDuration, Proc))) }
        attr_reader :max_staleness_setting

        sig { returns(T::Array[String]) }
        def dependency_tables
          tables = T.let(T.unsafe(self).instance_variable_get(:@dependency_tables), T.nilable(T::Array[String]))
          tables.nil? ? [] : tables
        end

        sig { params(subclass: T.class_of(View)).void }
        def inherited(subclass)
          super
          T.unsafe(subclass).instance_variable_set(:@dependency_tables, [])
          T.unsafe(subclass).instance_variable_set(:@refresh_strategy, nil)
          T.unsafe(subclass).instance_variable_set(:@refresh_debounce, nil)
          T.unsafe(subclass).instance_variable_set(:@refresh_mode, nil)
          T.unsafe(subclass).instance_variable_set(:@incremental_source_definition, nil)
          T.unsafe(subclass).instance_variable_set(:@incremental_key_columns, nil)
        end

        sig { returns(String) }
        def view_key
          return T.must(name).underscore if name.present?

          table = T.let(T.unsafe(self).instance_variable_get(:@table_name), T.nilable(String))
          table.presence || "anonymous_view_#{object_id}"
        end

        sig { params(sql: T.nilable(SourceDefinition), block: T.nilable(T.proc.returns(String))).void }
        def materialized_from(sql = nil, &block)
          @source_definition = T.let(sql || block, T.nilable(SourceDefinition))
          Registry.register(self) unless abstract_class?
        end

        sig { params(tables: T.any(Symbol, String)).void }
        def depends_on(*tables)
          DependencyRegistry.register(self, tables)
        end

        sig { params(strategy: Symbol).void }
        def refresh_on_change(strategy = :async)
          @refresh_strategy = T.let(strategy.to_sym, T.nilable(Symbol))
        end

        sig { params(seconds: DebounceInterval).void }
        def refresh_debounce(seconds)
          @refresh_debounce = T.let(seconds, T.nilable(DebounceInterval))
        end

        sig { params(mode: RefreshMode).void }
        def refresh_mode(mode)
          T.unsafe(self).instance_variable_set(:@refresh_mode, mode.to_sym)
        end

        sig { params(sql: T.nilable(SourceDefinition), block: T.nilable(T.proc.returns(String))).void }
        def incremental_from(sql = nil, &block)
          @incremental_source_definition = T.let(sql || block, T.nilable(SourceDefinition))
        end

        sig { params(columns: T.any(Symbol, String)).void }
        def incremental_keys(*columns)
          @incremental_key_columns = T.let(columns.map(&:to_s), T.nilable(T::Array[String]))
        end

        sig { returns(RefreshMode) }
        def resolved_refresh_mode
          mode = T.let(
            T.unsafe(self).instance_variable_get(:@refresh_mode),
            T.nilable(RefreshMode)
          )
          mode || :full
        end

        sig { returns(T::Array[String]) }
        def incremental_key_columns
          columns = T.let(
            T.unsafe(self).instance_variable_get(:@incremental_key_columns),
            T.nilable(T::Array[String])
          )
          columns.nil? ? [] : columns
        end

        sig { returns(T::Boolean) }
        def incremental_refresh_configured?
          incremental_key_columns.any? && !@incremental_source_definition.nil?
        end

        sig { returns(String) }
        def resolved_incremental_sql
          unless incremental_refresh_configured?
            raise ArgumentError,
                  "incremental_from and incremental_keys are required for incremental refresh on #{name || view_key}"
          end

          resolve_sql_definition(
            @incremental_source_definition,
            "incremental_from SQL is required for #{name || view_key}"
          )
        end

        sig { returns(Symbol) }
        def resolved_refresh_strategy
          @refresh_strategy || ActiveRecord::Materialized.configuration.default_refresh_strategy
        end

        sig { returns(T.any(Integer, Float)) }
        def resolved_refresh_debounce
          interval = @refresh_debounce.nil? ? ActiveRecord::Materialized.configuration.default_refresh_debounce : @refresh_debounce
          interval.respond_to?(:to_f) ? interval.to_f : interval.to_i
        end

        sig do
          params(
            duration: T.nilable(StalenessDuration),
            block: T.nilable(T.proc.returns(StalenessDuration))
          ).void
        end
        def max_staleness(duration = nil, &block)
          @max_staleness_setting = T.let(duration || block, T.nilable(T.any(StalenessDuration, Proc)))
        end

        sig { returns(T.nilable(StalenessDuration)) }
        def resolved_max_staleness
          setting = @max_staleness_setting
          default = ActiveRecord::Materialized.configuration.default_max_staleness
          return T.cast(default, T.nilable(StalenessDuration)) if setting.nil?
          return T.unsafe(self).instance_eval(&setting) if setting.is_a?(Proc)

          setting
        end

        sig { returns(String) }
        def resolved_source_sql
          resolve_sql_definition(
            @source_definition,
            "materialized_from SQL is required for #{name || view_key}"
          )
        end

        sig { returns(Metadata) }
        def metadata
          @metadata = T.let(@metadata, T.nilable(ActiveRecord::Materialized::Metadata))
          @metadata ||= ActiveRecord::Materialized::Metadata.new(self)
        end

        sig { returns(T::Boolean) }
        def stale?
          metadata.stale?
        end

        sig { returns(T::Boolean) }
        def dirty?
          metadata.dirty?
        end

        sig { returns(T.nilable(Timestamp)) }
        def last_refreshed_at
          metadata.last_refreshed_at
        end

        sig { returns(T::Boolean) }
        def refreshing?
          metadata.refreshing?
        end

        sig { void }
        def mark_dependencies_changed!
          metadata.mark_dirty!
        end

        sig { returns(T::Boolean) }
        def needs_refresh?
          return true unless table_exists?
          return true if metadata.last_refreshed_at.nil?
          return true if metadata.dirty?

          max_staleness = resolved_max_staleness
          return false if max_staleness.nil?

          metadata.stale?(max_staleness: max_staleness)
        end

        sig { params(force: T::Boolean).returns(RefreshResult) }
        def refresh!(force: false)
          Thread.current[:ar_materialized_refreshing] = true
          Refresher.new(self).refresh!(force: force)
        ensure
          Thread.current[:ar_materialized_refreshing] = false
        end

        sig { params(force: T::Boolean).returns(T.nilable(RefreshResult)) }
        def refresh_if_stale!(force: false)
          refresh!(force: force) if needs_refresh?
        end

        sig { returns(T::Boolean) }
        def table_exists?
          connection.data_source_exists?(table_name)
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

        sig { params(definition: T.nilable(SourceDefinition), empty_message: String).returns(String) }
        def resolve_sql_definition(definition, empty_message)
          sql = definition
          if sql.is_a?(Proc)
            sql = T.unsafe(sql).lambda? ? sql.call : T.unsafe(self).instance_eval(&sql)
          end
          sql = sql.call if sql.respond_to?(:call) && !sql.is_a?(String)
          raise ArgumentError, empty_message if sql.nil? || sql.strip.empty?

          sql
        end

        sig { void }
        def ensure_materialized!
          return if table_exists?
          return if Thread.current[:ar_materialized_refreshing]

          refresh!
        end
      end

      sig { returns(T::Boolean) }
      def stale?
        T.bind(self, View)
        self.class.stale?
      end
    end
  end
end
