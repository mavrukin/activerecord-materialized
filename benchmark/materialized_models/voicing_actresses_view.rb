# frozen_string_literal: true

class VoicingActressesView < ActiveRecord::Materialized::View
  self.table_name = "mv_voicing_actresses"

  materialized_from <<~SQL
    SELECT MIN(n.name) AS voicing_actress,
           MIN(t.title) AS jap_engl_voiced_movie
    FROM aka_name AS an,
         char_name AS chn,
         cast_info AS ci,
         company_name AS cn,
         info_type AS it,
         movie_companies AS mc,
         movie_info AS mi,
         name AS n,
         role_type AS rt,
         title AS t
    WHERE ci.note IN ('(voice)',
                      '(voice: Japanese version)',
                      '(voice) (uncredited)',
                      '(voice: English version)')
      AND cn.country_code = '[us]'
      AND it.info = 'release dates'
      AND n.gender = 'f'
      AND rt.role = 'actress'
      AND t.production_year > 2000
      AND t.id = mi.movie_id
      AND t.id = mc.movie_id
      AND t.id = ci.movie_id
      AND mc.movie_id = ci.movie_id
      AND mc.movie_id = mi.movie_id
      AND mi.movie_id = ci.movie_id
      AND cn.id = mc.company_id
      AND it.id = mi.info_type_id
      AND n.id = ci.person_id
      AND rt.id = ci.role_id
      AND n.id = an.person_id
      AND ci.person_id = an.person_id
      AND chn.id = ci.person_role_id
  SQL

  depends_on :aka_name, :char_name, :cast_info, :company_name, :info_type,
             :movie_companies, :movie_info, :name, :role_type, :title
  max_staleness 12.hours
end
