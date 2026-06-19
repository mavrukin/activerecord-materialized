# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class RefreshResult < T::Struct
      const :view_class, T.class_of(View)
      const :row_count, Integer
      const :duration_ms, Integer
      const :refreshed_at, T.nilable(Timestamp)
    end
  end
end
