-- Slow analytical query: multi-join aggregation with DISTINCT counts.
-- Typical runtime: 2-5 seconds on xlarge synthetic JOB data.
SELECT n.gender,
       COUNT(*) AS role_pairings,
       COUNT(DISTINCT ci.person_id) AS distinct_people,
       COUNT(DISTINCT ci.movie_id) AS distinct_movies
FROM cast_info AS ci,
     name AS n,
     title AS t,
     movie_companies AS mc,
     movie_info AS mi
WHERE t.production_year > 2000
  AND n.id = ci.person_id
  AND t.id = ci.movie_id
  AND mc.movie_id = t.id
  AND mi.movie_id = t.id
GROUP BY n.gender;
