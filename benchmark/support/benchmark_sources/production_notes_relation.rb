# frozen_string_literal: true

require_relative "../job_models"

module BenchmarkSources
  module ProductionNotesRelation
    extend ActiveRecord::Materialized::QueryExpressions

    module_function

    def production_notes_relation
      movie_company = Job::MovieCompany.arel_table
      note = movie_company[:note]

      Job::MovieCompany
        .from(movie_company)
        .joins(production_notes_joins)
        .merge(production_notes_filters(note))
        .select(*production_notes_columns)
    end

    def production_notes_filters(note)
      filters = [note.matches("%(co-production)%"), note.matches("%(presents)%")]
      Job::MovieCompany
        .where(Job::CompanyType.arel_table[:kind].eq("production companies"))
        .where(Job::InfoType.arel_table[:info].eq("top 250 rank"))
        .where(note.does_not_match("%(as Metro-Goldwyn-Mayer Pictures)%"))
        .where(filters.reduce { |left, right| left.or(right) })
    end

    def production_notes_joins
      movie_company = Job::MovieCompany.arel_table
      company_type = Job::CompanyType.arel_table
      titles = Job::Title.arel_table
      movie_info_idx = Job::MovieInfoIdx.arel_table
      info_types = Job::InfoType.arel_table

      # Chain every join onto the single movie_company select manager. Joining a
      # separately-built manager makes Arel emit it as a derived table
      # (`INNER JOIN (SELECT FROM ...)`), which is invalid SQL.
      movie_company
        .join(company_type).on(company_type[:id].eq(movie_company[:company_type_id]))
        .join(titles).on(titles[:id].eq(movie_company[:movie_id]))
        .join(movie_info_idx).on(movie_info_idx[:movie_id].eq(movie_company[:movie_id]))
        .join(info_types).on(info_types[:id].eq(movie_info_idx[:info_type_id]))
        .join_sources
    end

    def production_notes_columns
      movie_company = Job::MovieCompany.arel_table
      titles = Job::Title.arel_table
      [
        min_as(movie_company[:note], as: :production_note),
        min_as(titles[:title], as: :movie_title),
        min_as(titles[:production_year], as: :movie_year)
      ]
    end
  end
end
