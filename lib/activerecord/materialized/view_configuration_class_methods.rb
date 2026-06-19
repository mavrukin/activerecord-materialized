# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    module ViewConfigurationClassMethods
      extend T::Sig
      extend T::Helpers

      sig { params(base: T.class_of(View)).void }
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        extend T::Sig

        sig { params(subclass: T.class_of(View)).void }
        def inherited(subclass)
          super
          T.unsafe(subclass).instance_variable_set(:@dependency_tables, [])
          T.unsafe(subclass).instance_variable_set(:@refresh_strategy, nil)
          T.unsafe(subclass).instance_variable_set(:@refresh_debounce, nil)
        end

        sig { returns(String) }
        def view_key
          klass = view
          class_name = klass.name
          return class_name.underscore if class_name.present?

          table = T.let(T.unsafe(klass).instance_variable_get(:@table_name), T.nilable(String))
          table.presence || "anonymous_view_#{klass.object_id}"
        end

        sig { params(sql: T.nilable(SourceDefinition), block: T.nilable(T.proc.returns(String))).void }
        def materialized_from(sql = nil, &block)
          @source_definition = T.let(sql || block, T.nilable(SourceDefinition))
          Registry.register(view) unless view.abstract_class?
        end

        sig { params(tables: T.any(Symbol, String)).void }
        def depends_on(*tables)
          DependencyRegistry.register(view, tables)
        end

        sig { params(strategy: Symbol).void }
        def refresh_on_change(strategy = :async)
          @refresh_strategy = T.let(strategy.to_sym, T.nilable(Symbol))
        end

        sig { params(seconds: DebounceInterval).void }
        def refresh_debounce(seconds)
          @refresh_debounce = T.let(seconds, T.nilable(DebounceInterval))
        end

        sig { returns(Symbol) }
        def resolved_refresh_strategy
          @refresh_strategy || ActiveRecord::Materialized.configuration.default_refresh_strategy
        end

        sig { returns(T.any(Integer, Float)) }
        def resolved_refresh_debounce
          interval = if @refresh_debounce.nil?
                       ActiveRecord::Materialized.configuration.default_refresh_debounce
                     else
                       @refresh_debounce
                     end
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
          return T.unsafe(view).instance_eval(&setting) if setting.is_a?(Proc)

          setting
        end

        sig { returns(String) }
        def resolved_source_sql
          sql = T.must(ViewSourceDefinition.resolve(view, @source_definition))
          ViewSourceDefinition.validate!(view, sql)
          sql
        end

        sig { returns(Metadata) }
        def metadata
          @metadata = T.let(@metadata, T.nilable(ActiveRecord::Materialized::Metadata))
          @metadata ||= ActiveRecord::Materialized::Metadata.new(view)
        end

        sig { void }
        def mark_dependencies_changed!
          metadata.mark_dirty!
        end

        sig { returns(T.class_of(View)) }
        def view
          T.cast(self, T.class_of(View))
        end
      end

      mixes_in_class_methods ClassMethods
    end
  end
end
