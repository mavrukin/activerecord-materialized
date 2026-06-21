# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # One row per materialized partition of a cold view. A row's presence means
    # that partition has been materialized into the cache table and is current
    # ("fresh"); its absence means the partition is not yet materialized.
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
