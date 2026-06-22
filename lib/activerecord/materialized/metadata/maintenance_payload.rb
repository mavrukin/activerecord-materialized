# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class Metadata
      # Reads and writes the serialized pending-maintenance payload on the metadata row.
      #
      # @api private
      module MaintenancePayload
        extend T::Sig

        sig { params(metadata: Metadata, payload: T::Hash[String, T.untyped]).void }
        def self.record!(metadata, payload)
          metadata.record.update!(maintenance_payload: payload.to_json)
        end

        sig { params(metadata: Metadata).returns(T.nilable(T::Hash[String, T.untyped])) }
        def self.fetch(metadata)
          raw = T.unsafe(metadata.record).maintenance_payload
          return nil if raw.blank?

          JSON.parse(raw)
        end

        sig { params(metadata: Metadata).void }
        def self.clear!(metadata)
          metadata.record.update!(maintenance_payload: nil)
        end
      end
    end
  end
end
