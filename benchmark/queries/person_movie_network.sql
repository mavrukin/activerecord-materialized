-- Slow analytical query: deep join graph with per-person/per-movie grouping.
-- Typical runtime: 3-6 seconds on xlarge synthetic JOB data.
SELECT n.gender,
       t.production_year,
       COUNT(*) AS pairing_count,
       COUNT(DISTINCT ci.person_id) AS people,
       COUNT(DISTINCT t.id) AS movies
FROM cast_info AS ci,
     name AS n,
     title AS t,
     movie_companies AS mc,
     movie_info AS mi,
     movie_info_idx AS mii
WHERE t.production_year > 1995
  AND n.id = ci.person_id
  AND t.id = ci.movie_id
  AND mc.movie_id = t.id
  AND mi.movie_id = t.id
  AND mii.movie_id = t.id
  AND (ci.note LIKE '%voice%' OR ci.note LIKE '%standard%')
GROUP BY n.gender, t.production_year
HAVING COUNT(*) > 50;
