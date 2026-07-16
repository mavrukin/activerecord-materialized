# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # ActiveRecord model backing the materialized-view metadata table.
    #
    # @api private
    class MetadataRecord < ::ActiveRecord::Base
      @table_name_override = nil

      self.table_name = ::ActiveRecord::Materialized.metadata_table_name

      def self.table_name=(name)
        @table_name_override = name
      end

      def self.table_name
        override = @table_name_override
        override.nil? ? ::ActiveRecord::Materialized.metadata_table_name : override
      end
    end
  end
end
