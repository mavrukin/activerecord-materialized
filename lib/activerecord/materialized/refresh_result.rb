# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class RefreshResult < T::Struct
      extend T::Sig

      const :view_class, T.class_of(View)
      const :row_count, Integer
      const :duration_ms, Integer
      const :refreshed_at, T.nilable(Timestamp)
      const :skipped, T::Boolean, default: false

      # Returned when refresh! was requested on a view that is not maintainable.
      sig { params(view_class: T.class_of(View)).returns(RefreshResult) }
      def self.skipped(view_class)
        new(view_class: view_class, row_count: 0, duration_ms: 0, refreshed_at: nil, skipped: true)
      end
    end
  end
end
