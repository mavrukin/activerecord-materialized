# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # The `materialized_from` / `depends_on` DSL and source/metadata accessors mixed into every {View}.
    module ViewConfigurationClassMethods
      def self.included(base)
        base.extend(ClassMethods)
      end

      # The configuration DSL methods available on a {View} subclass.
      module ClassMethods
        include ViewIncrementalClassMethods::ClassMethods
        include ViewRefreshPolicyClassMethods::ClassMethods

        # Per-subclass DSL ivars reset to nil on inheritance so a subclass never
        # inherits another view's configuration. (`@dependency_tables` resets to
        # an empty list instead — see {inherited}.)
        NIL_RESET_IVARS = %i[
          @refresh_strategy @refresh_debounce @refresh_mode @incremental_source_definition
          @incremental_key_columns @partition_key_resolvers @cold_read_strategy @change_source
          @warm_up_definition
        ].freeze

        def view_class
          self
        end

        def inherited(subclass)
          super
          subclass.instance_variable_set(:@dependency_tables, [])
          NIL_RESET_IVARS.each { |ivar| subclass.instance_variable_set(ivar, nil) }
        end

        def view_key
          return view_class.name.underscore if view_class.name.present?

          table = view_class.instance_variable_get(:@table_name)
          table.presence || "anonymous_view_#{view_class.object_id}"
        end

        # Declares the source relation this view materializes and registers the view unless it is abstract.
        #
        # @yieldreturn [ActiveRecord::Relation] the query whose result set is cached in the view's table
        # @return [void]
        def materialized_from(&block)
          @source_definition = block
          Registry.register(view_class) unless view_class.abstract_class?
        end

        # Declares the dependency tables whose committed writes trigger maintenance of this view.
        #
        # @param tables [Array<Symbol, String, Class<ActiveRecord::Base>>] dependency tables this view reads from
        # @return [void]
        def depends_on(*tables)
          DependencyRegistry.register(view_class, tables)
        end

        def resolved_source
          resolve_source_definition(
            @source_definition,
            "materialized_from is required for #{view_class.name || view_class.view_key}"
          )
        end

        def metadata
          @metadata ||= ActiveRecord::Materialized::Metadata.new(view_class)
        end

        private

        def resolve_source_definition(definition, empty_message)
          source = coerce_source(definition)
          Kernel.raise ArgumentError, empty_message if source.nil?
          unless source.is_a?(::ActiveRecord::Relation)
            Kernel.raise ArgumentError, "#{empty_message}: expected ActiveRecord::Relation, got #{source.class}"
          end

          source
        end

        def coerce_source(definition)
          source = definition
          return source unless source.is_a?(Proc)

          source.call
        end
      end
    end
  end
end
