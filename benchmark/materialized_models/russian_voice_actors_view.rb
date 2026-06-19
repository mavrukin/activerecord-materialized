# frozen_string_literal: true

class RussianVoiceActorsView < ActiveRecord::Materialized::View
  self.table_name = "mv_russian_voice_actors"

  materialized_from { BenchmarkSources.russian_voice_actors_relation }

  depends_on :char_name, :cast_info, :company_name, :company_type, :movie_companies, :role_type, :title
  max_staleness 12.hours
end
