# frozen_string_literal: true

class CompanyMovieCrossView < ActiveRecord::Materialized::View
  self.table_name = "mv_company_movie_cross"

  materialized_from { BenchmarkSources.company_movie_cross_relation }

  depends_on :movie_companies, :company_name, :title, :cast_info, :movie_info
  refresh_on_change :async
  refresh_debounce 0
  max_staleness 12.hours
end
