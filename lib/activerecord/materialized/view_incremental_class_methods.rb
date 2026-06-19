# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    module ViewIncrementalClassMethods
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

        sig { params(mode: RefreshMode).void }
        def refresh_mode(mode)
          T.unsafe(self).instance_variable_set(:@refresh_mode, mode.to_sym)
        end

        sig { params(block: T.proc.returns(::ActiveRecord::Relation)).void }
        def incremental_from(&block)
          @incremental_source_definition = T.let(block, T.nilable(SourceDefinition))
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
          mode || :incremental
        end

        sig { returns(ViewDefinition) }
        def view_definition
          ViewDefinition.new(
            view_class.resolved_source,
            explicit_group_keys: incremental_key_columns.presence
          )
        end

        sig { returns(T::Array[String]) }
        def maintenance_key_columns
          return incremental_key_columns if incremental_key_columns.any?

          view_definition.group_key_columns
        end

        sig { returns(T::Boolean) }
        def incrementally_maintainable?
          resolved_refresh_mode != :full && view_definition.incrementally_maintainable?
        end

        sig { returns(T::Boolean) }
        def incremental_source_override?
          !@incremental_source_definition.nil?
        end

        sig { params(change: WriteChange).void }
        def record_write_change!(change)
          return unless incrementally_maintainable?

          delta = MaintenanceDeltaBuilder.new(change, maintenance_key_columns).build
          record_write_delta!(delta)
        end

        sig { params(delta: MaintenanceDelta).void }
        def record_write_delta!(delta)
          return unless incrementally_maintainable?

          MaintenanceStore.new(view_class).merge!(delta)
        end

        sig { returns(T::Array[String]) }
        def incremental_key_columns
          columns = T.let(
            T.unsafe(self).instance_variable_get(:@incremental_key_columns),
            T.nilable(T::Array[String])
          )
          columns.nil? ? [] : columns
        end

        sig { returns(::ActiveRecord::Relation) }
        def resolved_incremental_source
          unless incremental_source_override?
            Kernel.raise ArgumentError,
                         "incremental_from override is not configured for #{view_class.name || view_class.view_key}"
          end

          view_class.send(
            :resolve_source_definition,
            @incremental_source_definition,
            "incremental_from is required for #{view_class.name || view_class.view_key}"
          )
        end
      end

      mixes_in_class_methods ClassMethods
    end
  end
end
