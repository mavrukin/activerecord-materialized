# frozen_string_literal: true

class GenderPairingStatsView < ActiveRecord::Materialized::View
  self.table_name = "mv_gender_pairing_stats"

  materialized_from File.read(File.expand_path("../queries/gender_pairing_stats.sql", __dir__))

  depends_on :cast_info, :name, :title, :movie_companies, :movie_info
  refresh_on_change :async
  refresh_debounce 0
  max_staleness 12.hours
end
