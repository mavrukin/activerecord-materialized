# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class Metadata
      # Current-time and staleness-threshold helpers for metadata timestamps.
      #
      # @api private
      module Timestamps
        module_function

        def current
          ::Time.zone&.now || ::Time.now.utc
        end

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
