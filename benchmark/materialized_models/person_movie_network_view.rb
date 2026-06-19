# frozen_string_literal: true

class PersonMovieNetworkView < ActiveRecord::Materialized::View
  self.table_name = "mv_person_movie_network"

  materialized_from File.read(File.expand_path("../queries/person_movie_network.sql", __dir__))

  depends_on :cast_info, :name, :title, :movie_companies, :movie_info, :movie_info_idx
  refresh_on_change :async
  refresh_debounce 0
  max_staleness 12.hours
end
