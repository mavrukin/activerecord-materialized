# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Maps table names to their ActiveRecord models for dependency wiring.
    #
    # @api private
    class TableModelRegistry
      class << self
        def register(model_class)
          return if model_class.abstract_class?

          explicit[model_class.table_name] = model_class
        end

        def resolve(table_name)
          explicit[table_name] || find_descendant(table_name)
        end

        private

        def explicit
          @explicit ||= {}
        end

        def find_descendant(table_name)
          ::ActiveRecord::Base.descendants.find do |model_class|
            !model_class.abstract_class? && model_class.table_name == table_name
          end
        rescue StandardError
          nil
        end
      end
    end
  end
end
