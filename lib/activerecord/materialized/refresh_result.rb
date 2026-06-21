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

      # Returned when incremental maintenance was requested on a view that is not
      # warm/maintainable — nothing to do, no full build performed.
      sig { params(view_class: T.class_of(View)).returns(RefreshResult) }
      def self.skipped(view_class)
        new(view_class: view_class, row_count: 0, duration_ms: 0, refreshed_at: nil, skipped: true)
      end
    end
  end
end
