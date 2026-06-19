# frozen_string_literal: true

require_relative "../job_models"

module BenchmarkSources
  module CastAggregateRelations
    extend ActiveRecord::Materialized::QueryExpressions

    module_function

    def gender_pairing_stats_relation
      gender_pairing_scope.select(*gender_pairing_columns)
    end

    def gender_pairing_scope
      titles = Job::Title.arel_table
      Job::CastInfo
        .joins(:name, :title)
        .joins(title: %i[movie_companies movie_infos])
        .where(titles[:production_year].gt(2000))
        .group(Job::Name.arel_table[:gender])
    end

    def gender_pairing_columns
      names = Job::Name.arel_table
      cast = Job::CastInfo.arel_table
      [
        names[:gender],
        count_all_as(as: :role_pairings),
        count_distinct_as(cast[:person_id], as: :distinct_people),
        count_distinct_as(cast[:movie_id], as: :distinct_movies)
      ]
    end

    def company_movie_cross_relation
      company_movie_scope.select(*company_movie_columns)
    end

    def company_movie_scope
      mc = Job::MovieCompany.arel_table
      titles = Job::Title.arel_table
      Job::MovieCompany
        .joins(:company_name, :title)
        .joins(title: %i[cast_infos movie_infos])
        .where(titles[:production_year].gt(1985))
        .where(mc[:note].matches("%Metro%"))
        .group(Job::CompanyName.arel_table[:country_code])
    end

    def company_movie_columns
      companies = Job::CompanyName.arel_table
      mc = Job::MovieCompany.arel_table
      [
        companies[:country_code],
        count_distinct_as(mc[:movie_id], as: :movies),
        count_distinct_as(mc[:company_id], as: :companies),
        sum_length_as(mc[:note], as: :note_chars)
      ]
    end

    def person_movie_network_relation
      person_movie_scope.select(*person_movie_columns).having(Arel.star.count.gt(50))
    end

    def person_movie_scope
      cast = Job::CastInfo.arel_table
      titles = Job::Title.arel_table

      Job::CastInfo
        .joins(:name, :title)
        .joins(title: %i[movie_companies movie_infos movie_info_idxs])
        .where(titles[:production_year].gt(1995))
        .where(person_movie_note_filter(cast))
        .group(Job::Name.arel_table[:gender], titles[:production_year])
    end

    def person_movie_note_filter(cast)
      cast[:note].matches("%voice%").or(cast[:note].matches("%standard%"))
    end

    def person_movie_columns
      names = Job::Name.arel_table
      cast = Job::CastInfo.arel_table
      titles = Job::Title.arel_table
      [
        names[:gender],
        titles[:production_year],
        count_all_as(as: :pairing_count),
        count_distinct_as(cast[:person_id], as: :people),
        count_distinct_as(titles[:id], as: :movies)
      ]
    end
  end
end
