# frozen_string_literal: true

class VoicingActressesView < ActiveRecord::Materialized::View
  self.table_name = "mv_voicing_actresses"

  materialized_from { BenchmarkSources.voicing_actresses_relation }

  depends_on :aka_name, :char_name, :cast_info, :company_name, :info_type,
             :movie_companies, :movie_info, :name, :role_type, :title
  max_staleness 12.hours
end
