# frozen_string_literal: true

class ProductionNotesView < ActiveRecord::Materialized::View
  self.table_name = "mv_production_notes"

  materialized_from { BenchmarkSources.production_notes_relation }

  depends_on :company_type, :info_type, :movie_companies, :movie_info_idx, :title
  max_staleness 12.hours
end
