# frozen_string_literal: true

require_relative "../job_models"

module BenchmarkSources
  module VoiceCastRelations
    extend ActiveRecord::Materialized::QueryExpressions

    VOICE_NOTES = [
      "(voice)",
      "(voice: Japanese version)",
      "(voice) (uncredited)",
      "(voice: English version)"
    ].freeze

    module_function

    def voicing_actresses_relation
      voicing_actresses_scope.select(*voicing_actresses_columns)
    end

    def voicing_actresses_scope
      titles = Job::Title.arel_table
      Job::CastInfo
        .joins(:name, :title, :char_name, :role_type, :aka_names)
        .joins(title: { movie_companies: :company_name })
        .merge(voicing_actresses_filters)
        .where(titles[:production_year].gt(2000))
    end

    def voicing_actresses_filters
      cast = Job::CastInfo.arel_table
      Job::CastInfo
        .joins(:movie_infos)
        .joins(movie_infos: :info_type)
        .merge(voicing_actress_identity_filters(cast))
    end

    def voicing_actress_identity_filters(cast)
      Job::CastInfo
        .merge(voicing_actress_note_filters(cast))
        .merge(voicing_actress_role_filters)
    end

    def voicing_actress_note_filters(cast)
      Job::CastInfo
        .where(cast[:note].in(VOICE_NOTES))
        .where(Job::CompanyName.arel_table[:country_code].eq("[us]"))
        .where(Job::InfoType.arel_table[:info].eq("release dates"))
    end

    def voicing_actress_role_filters
      Job::CastInfo
        .where(Job::Name.arel_table[:gender].eq("f"))
        .where(Job::RoleType.arel_table[:role].eq("actress"))
    end

    def voicing_actresses_columns
      names = Job::Name.arel_table
      titles = Job::Title.arel_table
      [
        min_as(names[:name], as: :voicing_actress),
        min_as(titles[:title], as: :jap_engl_voiced_movie)
      ]
    end

    def russian_voice_actors_relation
      russian_voice_scope.select(*russian_voice_columns)
    end

    def russian_voice_scope
      titles = Job::Title.arel_table
      Job::CastInfo
        .joins(:char_name, :role_type, :title)
        .joins(title: { movie_companies: %i[company_name company_type] })
        .merge(russian_voice_filters)
        .where(titles[:production_year].gt(2005))
    end

    def russian_voice_filters
      cast = Job::CastInfo.arel_table
      Job::CastInfo
        .where(cast[:note].matches("%(voice)%"))
        .where(cast[:note].matches("%(uncredited)%"))
        .where(Job::CompanyName.arel_table[:country_code].eq("[ru]"))
        .where(Job::RoleType.arel_table[:role].eq("actor"))
    end

    def russian_voice_columns
      chn = Job::CharName.arel_table
      titles = Job::Title.arel_table
      [
        min_as(chn[:name], as: :uncredited_voiced_character),
        min_as(titles[:title], as: :russian_movie)
      ]
    end
  end
end
