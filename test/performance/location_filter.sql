-- Run with: psql -X -d photos_test -v ON_ERROR_STOP=1 -f test/performance/location_filter.sql
-- Session-local synthetic data only. Uses the existing coordinate index shape.
CREATE TEMP TABLE benchmark_metadata (
  photo_id bigint PRIMARY KEY,
  latitude numeric(10, 6),
  longitude numeric(10, 6)
);
INSERT INTO benchmark_metadata
SELECT n,
  CASE WHEN n % 20 = 0 THEN NULL ELSE -12.5 + (n % 1000) * 0.025 + (n / 4000) * 0.000001 END,
  -50 + (n % 4000) * 0.025 + (n / 4000) * 0.000001
FROM generate_series(1, 100000) n;

CREATE INDEX benchmark_metadata_coordinates ON benchmark_metadata (latitude, longitude)
WHERE latitude IS NOT NULL AND longitude IS NOT NULL;
ANALYZE benchmark_metadata;

CREATE TEMP VIEW benchmark_location_before AS
SELECT photo_id FROM benchmark_metadata
WHERE FLOOR(latitude / 0.025) = 41 AND FLOOR(longitude / 0.025) = -459;
CREATE TEMP VIEW benchmark_location_after AS
SELECT photo_id FROM benchmark_metadata
WHERE latitude >= 1.025 AND latitude < 1.050 AND longitude >= -11.475 AND longitude < -11.450;

DO $$
BEGIN
  IF EXISTS (
    (SELECT * FROM benchmark_location_before EXCEPT SELECT * FROM benchmark_location_after)
    UNION ALL
    (SELECT * FROM benchmark_location_after EXCEPT SELECT * FROM benchmark_location_before)
  ) THEN
    RAISE EXCEPTION 'Location results differ';
  END IF;
END $$;

\echo 'Before: computed coordinate bucket'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) SELECT * FROM benchmark_location_before;
\echo 'After: indexed coordinate ranges'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) SELECT * FROM benchmark_location_after;

\echo 'Before: named location containing multiple buckets'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT photo_id FROM benchmark_metadata
WHERE (FLOOR(latitude / 0.025) = 41 AND FLOOR(longitude / 0.025) = -459)
   OR (FLOOR(latitude / 0.025) = 43 AND FLOOR(longitude / 0.025) = -457);
\echo 'After: named location containing multiple indexed ranges'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT photo_id FROM benchmark_metadata
WHERE (latitude >= 1.025 AND latitude < 1.050 AND longitude >= -11.475 AND longitude < -11.450)
   OR (latitude >= 1.075 AND latitude < 1.100 AND longitude >= -11.425 AND longitude < -11.400);
