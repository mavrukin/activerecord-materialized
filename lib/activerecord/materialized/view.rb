# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class View < ::ActiveRecord::Base
      extend T::Sig
      include RefreshCallbacks
      include ViewConfigurationClassMethods
      include ViewQueryAccessClassMethods

      self.abstract_class = true

      class << self
        extend T::Sig

        @source_definition = T.let(nil, T.nilable(SourceDefinition))
        @max_staleness_setting = T.let(nil, T.nilable(T.any(StalenessDuration, Proc)))
        @dependency_tables = T.let(nil, T.nilable(T::Array[String]))
        @refresh_strategy = T.let(nil, T.nilable(Symbol))
        @refresh_debounce = T.let(nil, T.nilable(DebounceInterval))
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
      end

      sig { returns(T::Boolean) }
      def stale?
        T.bind(self, View)
        self.class.stale?
      end
    end
  end
end
