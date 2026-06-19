-- Expensive self-join: count co-appearing cast pairs per movie.
-- Heavily stresses join cardinality; typically multi-second on xlarge/stress data.
SELECT t.production_year,
       COUNT(*) AS coappearance_pairs,
       COUNT(DISTINCT ci1.movie_id) AS movies
FROM cast_info AS ci1,
     cast_info AS ci2,
     title AS t
WHERE ci1.movie_id = ci2.movie_id
  AND ci1.person_id < ci2.person_id
  AND t.id = ci1.movie_id
  AND t.production_year > 1990
GROUP BY t.production_year
HAVING COUNT(*) > 1000;
