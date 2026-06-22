# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # One row per fresh partition of a cold view; presence means the partition is
    # materialized and current, absence means it is not.
    class PartitionRecord < ::ActiveRecord::Base
      extend T::Sig

      @table_name_override = T.let(nil, T.nilable(String))

      self.table_name = ::ActiveRecord::Materialized.partition_table_name

      sig { params(name: String).void }
      def self.table_name=(name)
        @table_name_override = name
      end

      sig { returns(String) }
      def self.table_name
        override = @table_name_override
        override.nil? ? ::ActiveRecord::Materialized.partition_table_name : override
      end
    end
  end
end
