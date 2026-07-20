# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # ActiveRecord model backing the write-outbox table — the durable queue that database triggers
    # append to when a dependency table is written out-of-band (raw SQL, another service, a backfill).
    # {WriteOutbox.drain!} relays these rows through the ingestion API. Uses {ConfigurableTableName}'s
    # dynamic resolution so a host app can rename the table via configuration.
    #
    # @api private
    class WriteOutboxRecord < ::ActiveRecord::Base
      include ConfigurableTableName

      configurable_table_name { ::ActiveRecord::Materialized.configuration.write_outbox_table_name }
    end
  end
end
