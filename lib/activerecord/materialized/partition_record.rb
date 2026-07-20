# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # One row per fresh partition of a cold view; presence means the partition is
    # materialized and current, absence means it is not.
    class PartitionRecord < ::ActiveRecord::Base
      include ConfigurableTableName

      configurable_table_name { ::ActiveRecord::Materialized.partition_table_name }
    end
  end
end
