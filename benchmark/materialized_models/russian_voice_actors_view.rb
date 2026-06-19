# frozen_string_literal: true

class RussianVoiceActorsView < ActiveRecord::Materialized::View
  self.table_name = "mv_russian_voice_actors"

  materialized_from <<~SQL.squish
    SELECT MIN(chn.name) AS uncredited_voiced_character,
           MIN(t.title) AS russian_movie
    FROM char_name AS chn,
         cast_info AS ci,
         company_name AS cn,
         company_type AS ct,
         movie_companies AS mc,
         role_type AS rt,
         title AS t
    WHERE ci.note LIKE '%(voice)%'
      AND ci.note LIKE '%(uncredited)%'
      AND cn.country_code = '[ru]'
      AND rt.role = 'actor'
      AND t.production_year > 2005
      AND t.id = mc.movie_id
      AND t.id = ci.movie_id
      AND ci.movie_id = mc.movie_id
      AND chn.id = ci.person_role_id
      AND rt.id = ci.role_id
      AND cn.id = mc.company_id
      AND ct.id = mc.company_type_id
  SQL

  depends_on :char_name, :cast_info, :company_name, :company_type, :movie_companies, :role_type, :title
  max_staleness 12.hours
end
