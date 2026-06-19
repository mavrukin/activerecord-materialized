# frozen_string_literal: true

class CastCoappearanceView < ActiveRecord::Materialized::View
  self.table_name = "mv_cast_coappearance"

  materialized_from BenchmarkSupport::SqlLoader.load("cast_coappearance.sql")

  depends_on :cast_info, :title
  refresh_on_change :async
  refresh_debounce 0
  max_staleness 12.hours
end
