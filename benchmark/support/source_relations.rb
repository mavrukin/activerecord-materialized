# frozen_string_literal: true

require_relative "job_models"

module BenchmarkSources
  extend ActiveRecord::Materialized::QueryExpressions

  VOICE_NOTES = [
    "(voice)",
    "(voice: Japanese version)",
    "(voice) (uncredited)",
    "(voice: English version)"
  ].freeze

  module_function

  def gender_pairing_stats_relation
    names = Job::Name.arel_table
    cast = Job::CastInfo.arel_table
    titles = Job::Title.arel_table

    Job::CastInfo
      .joins(:name, :title)
      .joins(title: %i[movie_companies movie_infos])
      .where(titles[:production_year].gt(2000))
      .group(names[:gender])
      .select(
        names[:gender],
        count_all_as(as: :role_pairings),
        count_distinct_as(cast[:person_id], as: :distinct_people),
        count_distinct_as(cast[:movie_id], as: :distinct_movies)
      )
  end

  def company_movie_cross_relation
    companies = Job::CompanyName.arel_table
    mc = Job::MovieCompany.arel_table
    titles = Job::Title.arel_table

    Job::MovieCompany
      .joins(:company_name, :title)
      .joins(title: %i[cast_infos movie_infos])
      .where(titles[:production_year].gt(1985))
      .where(mc[:note].matches("%Metro%"))
      .group(companies[:country_code])
      .select(
        companies[:country_code],
        count_distinct_as(mc[:movie_id], as: :movies),
        count_distinct_as(mc[:company_id], as: :companies),
        sum_length_as(mc[:note], as: :note_chars)
      )
  end

  def person_movie_network_relation
    names = Job::Name.arel_table
    cast = Job::CastInfo.arel_table
    titles = Job::Title.arel_table
    pairing_count = Arel.star.count
    voice_note = cast[:note].matches("%voice%")
    standard_note = cast[:note].matches("%standard%")

    Job::CastInfo
      .joins(:name, :title)
      .joins(title: %i[movie_companies movie_infos movie_info_idxs])
      .where(titles[:production_year].gt(1995))
      .where(voice_note.or(standard_note))
      .group(names[:gender], titles[:production_year])
      .select(
        names[:gender],
        titles[:production_year],
        count_all_as(as: :pairing_count),
        count_distinct_as(cast[:person_id], as: :people),
        count_distinct_as(titles[:id], as: :movies)
      )
      .having(pairing_count.gt(50))
  end

  def cast_coappearance_relation
    ci = Job::CastInfo.arel_table
    ci2 = Job::CastInfo.arel_table.alias("ci2")
    titles = Job::Title.arel_table
    pairing_count = Arel.star.count

    Job::CastInfo
      .joins(
        ci.join(ci2).on(
          ci[:movie_id].eq(ci2[:movie_id]).and(ci[:person_id].lt(ci2[:person_id]))
        ).join_sources
      )
      .joins(:title)
      .where(titles[:production_year].gt(1990))
      .group(titles[:production_year])
      .select(
        titles[:production_year],
        count_all_as(as: :coappearance_pairs),
        count_distinct_as(ci[:movie_id], as: :movies)
      )
      .having(pairing_count.gt(1000))
  end

  def production_notes_relation
    mc = Job::MovieCompany.arel_table
    ct = Job::CompanyType.arel_table
    info_types = Job::InfoType.arel_table
    titles = Job::Title.arel_table
    mi_idx = Job::MovieInfoIdx.arel_table

    note = mc[:note]
    co_production = note.matches("%(co-production)%")
    presents = note.matches("%(presents)%")
    metro_exclusion = note.does_not_match("%(as Metro-Goldwyn-Mayer Pictures)%")

    join_sources = mc
                   .join(ct).on(ct[:id].eq(mc[:company_type_id]))
                   .join(titles).on(titles[:id].eq(mc[:movie_id]))
                   .join(mi_idx).on(mi_idx[:movie_id].eq(mc[:movie_id]))
                   .join(info_types).on(info_types[:id].eq(mi_idx[:info_type_id]))
                   .join_sources

    Job::MovieCompany
      .from(mc)
      .joins(join_sources)
      .where(ct[:kind].eq("production companies"))
      .where(info_types[:info].eq("top 250 rank"))
      .where(metro_exclusion)
      .where(co_production.or(presents))
      .select(
        min_as(mc[:note], as: :production_note),
        min_as(titles[:title], as: :movie_title),
        min_as(titles[:production_year], as: :movie_year)
      )
  end

  def voicing_actresses_relation
    names = Job::Name.arel_table
    titles = Job::Title.arel_table
    cast = Job::CastInfo.arel_table
    cn = Job::CompanyName.arel_table
    rt = Job::RoleType.arel_table
    info_types = Job::InfoType.arel_table

    Job::CastInfo
      .joins(:name, :title, :char_name, :role_type, :aka_names)
      .joins(title: { movie_companies: :company_name })
      .joins(:movie_infos)
      .joins(movie_infos: :info_type)
      .where(cast[:note].in(VOICE_NOTES))
      .where(cn[:country_code].eq("[us]"))
      .where(info_types[:info].eq("release dates"))
      .where(names[:gender].eq("f"))
      .where(rt[:role].eq("actress"))
      .where(titles[:production_year].gt(2000))
      .select(
        min_as(names[:name], as: :voicing_actress),
        min_as(titles[:title], as: :jap_engl_voiced_movie)
      )
  end

  def russian_voice_actors_relation
    chn = Job::CharName.arel_table
    cast = Job::CastInfo.arel_table
    cn = Job::CompanyName.arel_table
    rt = Job::RoleType.arel_table
    titles = Job::Title.arel_table

    Job::CastInfo
      .joins(:char_name, :role_type, :title)
      .joins(title: { movie_companies: %i[company_name company_type] })
      .where(cast[:note].matches("%(voice)%"))
      .where(cast[:note].matches("%(uncredited)%"))
      .where(cn[:country_code].eq("[ru]"))
      .where(rt[:role].eq("actor"))
      .where(titles[:production_year].gt(2005))
      .select(
        min_as(chn[:name], as: :uncredited_voiced_character),
        min_as(titles[:title], as: :russian_movie)
      )
  end
end
