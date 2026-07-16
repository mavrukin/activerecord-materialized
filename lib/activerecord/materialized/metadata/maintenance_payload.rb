# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class Metadata
      # Reads and writes the serialized pending-maintenance payload on the metadata row.
      #
      # @api private
      module MaintenancePayload
        def self.record!(metadata, payload)
          metadata.record.update!(maintenance_payload: payload.to_json)
        end

        def self.fetch(metadata)
          raw = metadata.record.maintenance_payload
          return nil if raw.blank?

          JSON.parse(raw)
        end

        def self.clear!(metadata)
          metadata.record.update!(maintenance_payload: nil)
        end
      end
    end
  end
end
