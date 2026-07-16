# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # The outcome of a refresh or rebuild, returned by
    # {ViewQueryAccessClassMethods::ClassMethods#refresh! refresh!},
    # {ViewQueryAccessClassMethods::ClassMethods#rebuild! rebuild!}, and
    # {ViewQueryAccessClassMethods::ClassMethods#refresh_if_stale! refresh_if_stale!}.
    #
    # @!attribute [r] view_class
    #   @return [Class] the view that was refreshed
    # @!attribute [r] row_count
    #   @return [Integer] rows in the cache table after the operation
    # @!attribute [r] duration_ms
    #   @return [Integer] wall-clock duration in milliseconds
    # @!attribute [r] refreshed_at
    #   @return [Time, nil] when the refresh completed (nil when skipped)
    # @!attribute [r] skipped
    #   @return [Boolean] true when there was nothing to do (e.g. an unmaintainable view)
    RefreshResult = Data.define(:view_class, :row_count, :duration_ms, :refreshed_at, :skipped) do
      def initialize(view_class:, row_count:, duration_ms:, refreshed_at: nil, skipped: false) = super

      # A no-op result, returned when refresh! was requested on a view that is
      # not maintainable.
      #
      # @return [RefreshResult]
      def self.skipped(view_class)
        new(view_class: view_class, row_count: 0, duration_ms: 0, refreshed_at: nil, skipped: true)
      end
    end
  end
end
