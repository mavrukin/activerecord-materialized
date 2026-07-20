# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # ActiveRecord model backing the materialized-view metadata table.
    #
    # @api private
    class MetadataRecord < ::ActiveRecord::Base
      include ConfigurableTableName

      configurable_table_name { ::ActiveRecord::Materialized.metadata_table_name }
    end
  end
end
