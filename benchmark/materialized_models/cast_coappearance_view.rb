# frozen_string_literal: true

class CastCoappearanceView < ActiveRecord::Materialized::View
  self.table_name = "mv_cast_coappearance"

  materialized_from { BenchmarkSources.cast_coappearance_relation }

  depends_on :cast_info, :title
  max_staleness 12.hours
end
