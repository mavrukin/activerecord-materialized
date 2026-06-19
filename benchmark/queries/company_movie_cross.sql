-- Slow analytical query: cross-table joins with LIKE filter and aggregations.
-- Typical runtime: 2-4 seconds on xlarge synthetic JOB data.
SELECT cn.country_code,
       COUNT(DISTINCT mc.movie_id) AS movies,
       COUNT(DISTINCT mc.company_id) AS companies,
       SUM(LENGTH(mc.note)) AS note_chars
FROM movie_companies AS mc,
     company_name AS cn,
     title AS t,
     cast_info AS ci,
     movie_info AS mi
WHERE t.production_year > 1985
  AND mc.note LIKE '%Metro%'
  AND cn.id = mc.company_id
  AND t.id = mc.movie_id
  AND ci.movie_id = mc.movie_id
  AND mi.movie_id = mc.movie_id
GROUP BY cn.country_code;
