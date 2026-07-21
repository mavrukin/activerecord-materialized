# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # ActiveRecord model backing the CDC source-watermark table — the max applied +source_ts+ per
    # (view, partition). Used to suppress stale/out-of-order CDC events and to report a view's
    # freshness. Uses {ConfigurableTableName}'s dynamic resolution so a host app can rename the table.
    #
    # @api private
    class SourceWatermarkRecord < ::ActiveRecord::Base
      include ConfigurableTableName

      configurable_table_name { ::ActiveRecord::Materialized.configuration.source_watermark_table_name }
    end
  end
end
