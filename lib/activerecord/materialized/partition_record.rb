# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # One row per fresh partition of a cold view; presence means the partition is
    # materialized and current, absence means it is not.
    class PartitionRecord < ::ActiveRecord::Base
      @table_name_override = nil

      self.table_name = ::ActiveRecord::Materialized.partition_table_name

      def self.table_name=(name)
        @table_name_override = name
      end

      def self.table_name
        override = @table_name_override
        override.nil? ? ::ActiveRecord::Materialized.partition_table_name : override
      end
    end
  end
end
