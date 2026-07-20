# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # ActiveRecord model backing the write-outbox table — the durable queue that database triggers
    # append to when a dependency table is written out-of-band (raw SQL, another service, a backfill).
    # {WriteOutbox.drain!} relays these rows through the ingestion API. Mirrors {MetadataRecord}'s
    # dynamic table-name resolution so a host app can rename the table via configuration.
    #
    # @api private
    class WriteOutboxRecord < ::ActiveRecord::Base
      @table_name_override = nil

      self.table_name = ::ActiveRecord::Materialized.configuration.write_outbox_table_name

      def self.table_name=(name)
        @table_name_override = name
      end

      def self.table_name
        override = @table_name_override
        override.nil? ? ::ActiveRecord::Materialized.configuration.write_outbox_table_name : override
      end
    end
  end
end
