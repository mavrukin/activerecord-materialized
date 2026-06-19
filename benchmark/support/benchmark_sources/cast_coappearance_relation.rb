# frozen_string_literal: true

require_relative "../job_models"

module BenchmarkSources
  module CastCoappearanceRelation
    extend ActiveRecord::Materialized::QueryExpressions

    module_function

    def cast_coappearance_relation
      cast_coappearance_scope.select(*cast_coappearance_columns).having(Arel.star.count.gt(1000))
    end

    def cast_coappearance_scope
      titles = Job::Title.arel_table

      Job::CastInfo
        .joins(coappearance_join_sources)
        .joins(:title)
        .where(titles[:production_year].gt(1990))
        .group(titles[:production_year])
    end

    def coappearance_join_sources
      ci = Job::CastInfo.arel_table
      ci2 = Job::CastInfo.arel_table.alias("ci2")
      ci.join(ci2).on(
        ci[:movie_id].eq(ci2[:movie_id]).and(ci[:person_id].lt(ci2[:person_id]))
      ).join_sources
    end

    def cast_coappearance_columns
      ci = Job::CastInfo.arel_table
      titles = Job::Title.arel_table
      [
        titles[:production_year],
        count_all_as(as: :coappearance_pairs),
        count_distinct_as(ci[:movie_id], as: :movies)
      ]
    end
  end
end
