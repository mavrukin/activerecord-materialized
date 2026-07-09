# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # The `materialized_from` / `depends_on` DSL and source/metadata accessors mixed into every {View}.
    module ViewConfigurationClassMethods
      extend T::Sig
      extend T::Helpers

      sig { params(base: T.class_of(View)).void }
      def self.included(base)
        base.extend(ClassMethods)
      end

      # The configuration DSL methods available on a {View} subclass.
      module ClassMethods
        extend T::Sig
        include ViewIncrementalClassMethods::ClassMethods
        include ViewRefreshPolicyClassMethods::ClassMethods

        # Per-subclass DSL ivars reset to nil on inheritance so a subclass never
        # inherits another view's configuration. (`@dependency_tables` resets to
        # an empty list instead — see {inherited}.)
        NIL_RESET_IVARS = T.let(
          %i[
            @refresh_strategy @refresh_debounce @refresh_mode @incremental_source_definition
            @incremental_key_columns @partition_key_resolvers @cold_read_strategy @change_source
            @warm_up_definition
          ].freeze,
          T::Array[Symbol]
        )

        sig { returns(T.class_of(View)) }
        def view_class
          T.cast(self, T.class_of(View))
        end

        sig { params(subclass: T.class_of(View)).void }
        def inherited(subclass)
          super
          T.unsafe(subclass).instance_variable_set(:@dependency_tables, [])
          NIL_RESET_IVARS.each { |ivar| T.unsafe(subclass).instance_variable_set(ivar, nil) }
        end

        sig { returns(String) }
        def view_key
          return T.must(view_class.name).underscore if view_class.name.present?

          table = T.let(T.unsafe(view_class).instance_variable_get(:@table_name), T.nilable(String))
          table.presence || "anonymous_view_#{view_class.object_id}"
        end

        sig { params(block: T.proc.returns(::ActiveRecord::Relation)).void }
        def materialized_from(&block)
          @source_definition = T.let(block, T.nilable(SourceDefinition))
          Registry.register(view_class) unless view_class.abstract_class?
        end

        sig { params(tables: T.any(Symbol, String, T.class_of(::ActiveRecord::Base))).void }
        def depends_on(*tables)
          DependencyRegistry.register(view_class, tables)
        end

        sig { returns(::ActiveRecord::Relation) }
        def resolved_source
          resolve_source_definition(
            @source_definition,
            "materialized_from is required for #{view_class.name || view_class.view_key}"
          )
        end

        sig { returns(Metadata) }
        def metadata
          @metadata = T.let(@metadata, T.nilable(ActiveRecord::Materialized::Metadata))
          @metadata ||= ActiveRecord::Materialized::Metadata.new(view_class)
        end

        private

        sig do
          params(
            definition: T.nilable(SourceDefinition),
            empty_message: String
          ).returns(::ActiveRecord::Relation)
        end
        def resolve_source_definition(definition, empty_message)
          source = coerce_source(definition)
          Kernel.raise ArgumentError, empty_message if source.nil?
          unless source.is_a?(::ActiveRecord::Relation)
            Kernel.raise ArgumentError, "#{empty_message}: expected ActiveRecord::Relation, got #{source.class}"
          end

          source
        end

        sig { params(definition: T.nilable(SourceDefinition)).returns(T.untyped) }
        def coerce_source(definition)
          source = definition
          return source unless source.is_a?(Proc)

          source.call
        end
      end

      mixes_in_class_methods ClassMethods
    end
  end
end
