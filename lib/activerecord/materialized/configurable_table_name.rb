# frozen_string_literal: true

require "active_support/concern"

module ActiveRecord
  module Materialized
    # Dynamic table-name resolution shared by the gem's internal AR models (metadata, partition,
    # write-outbox). The default name is re-read from its configured source on every access, so a host
    # app can rename the table via {Materialized.configure}; a test or app can still pin an explicit
    # name with +self.table_name = "x"+, which then wins. Factored out of the three models so the
    # order-sensitive idiom lives in one place.
    #
    # @api private
    module ConfigurableTableName
      extend ActiveSupport::Concern

      included do
        # A class_attribute (not a bare class-instance var) so a subclass inherits the resolver and
        # resolves the default instead of raising NoMethodError on +table_name+.
        class_attribute :table_name_resolver, instance_accessor: false
      end

      class_methods do
        # Declare how the default table name is resolved. The +resolver+ block is called on each
        # {table_name} read (dynamic), unless an explicit name was assigned via +self.table_name=+.
        #
        # @yieldreturn [String] the currently-configured table name
        def configurable_table_name(&resolver)
          self.table_name_resolver = resolver
          # Seed ActiveRecord's internal @table_name once through its real setter, before the reader
          # below shadows it, so any internal that reads the raw ivar sees a value. (arel_table /
          # quoted_table_name are nilled by the setter and rebuild lazily through the overridden reader.)
          self.table_name = table_name_resolver.call
          @table_name_override = nil

          define_singleton_method(:table_name) do
            override = @table_name_override
            override.nil? ? table_name_resolver.call : override
          end
          define_singleton_method(:table_name=) { |name| @table_name_override = name }
        end
      end
    end
  end
end
