# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class Metadata
      # Current-time and staleness-threshold helpers for metadata timestamps.
      #
      # @api private
      module Timestamps
        extend T::Sig

        module_function

        sig { returns(Timestamp) }
        def current
          ::Time.zone&.now || ::Time.now.utc
        end

        sig { params(staleness: StalenessDuration).returns(Timestamp) }
        def threshold(staleness)
          if staleness.is_a?(Integer)
            ::ActiveSupport::Duration.seconds(staleness).ago
          else
            staleness.ago
          end
        end
      end
    end
  end
end
