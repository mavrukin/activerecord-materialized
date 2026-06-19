# frozen_string_literal: true

class PersonMovieNetworkView < ActiveRecord::Materialized::View
  self.table_name = "mv_person_movie_network"

  materialized_from { BenchmarkSources.person_movie_network_relation }

  depends_on :cast_info, :name, :title, :movie_companies, :movie_info, :movie_info_idx
  max_staleness 12.hours
end
