-- Run with: psql -X -d photos_test -v ON_ERROR_STOP=1 -f test/performance/health_patrol.sql
-- Session-local synthetic tables only; application records are untouched.
CREATE TEMP TABLE benchmark_patrol_photos (id bigint PRIMARY KEY, byte_size bigint);
CREATE TEMP TABLE benchmark_patrol_checks (
  id bigint PRIMARY KEY,
  photo_id bigint NOT NULL,
  checked_at timestamp NOT NULL
);

INSERT INTO benchmark_patrol_photos
SELECT n, CASE WHEN n % 13 = 0 THEN NULL ELSE n % 1000 END
FROM generate_series(1, 40000) n;

INSERT INTO benchmark_patrol_checks
SELECT (photo.id - 1) * 12 + history, photo.id,
  CASE WHEN photo.id % 15 = 0 AND history = 12 THEN TIMESTAMP '2026-01-10 12:00:00'
       ELSE TIMESTAMP '2026-01-01' + history * INTERVAL '1 hour' END
FROM benchmark_patrol_photos photo CROSS JOIN generate_series(1, 12) history
WHERE photo.id % 10 != 0;

CREATE INDEX ON benchmark_patrol_checks (photo_id, checked_at);
ANALYZE benchmark_patrol_photos;
ANALYZE benchmark_patrol_checks;

CREATE TEMP VIEW benchmark_patrol_before AS
SELECT photo.id FROM benchmark_patrol_photos photo
LEFT JOIN (
  SELECT DISTINCT ON (photo_id) * FROM benchmark_patrol_checks
  ORDER BY photo_id, checked_at DESC, id DESC
) latest ON latest.photo_id = photo.id
WHERE latest.id IS NULL OR latest.checked_at < TIMESTAMP '2026-01-10'
ORDER BY latest.checked_at ASC NULLS FIRST, photo.byte_size ASC NULLS LAST, photo.id ASC
LIMIT 100;

CREATE TEMP VIEW benchmark_patrol_after AS
SELECT photo.id FROM benchmark_patrol_photos photo
LEFT JOIN LATERAL (
  SELECT checked_at FROM benchmark_patrol_checks
  WHERE photo_id = photo.id ORDER BY checked_at DESC LIMIT 1
) latest ON true
WHERE latest.checked_at IS NULL OR latest.checked_at < TIMESTAMP '2026-01-10'
ORDER BY latest.checked_at ASC NULLS FIRST, photo.byte_size ASC NULLS LAST, photo.id ASC
LIMIT 100;

DO $$
BEGIN
  IF EXISTS (
    (SELECT * FROM benchmark_patrol_before EXCEPT ALL SELECT * FROM benchmark_patrol_after)
    UNION ALL
    (SELECT * FROM benchmark_patrol_after EXCEPT ALL SELECT * FROM benchmark_patrol_before)
  ) THEN
    RAISE EXCEPTION 'Patrol selections differ';
  END IF;
END $$;

\echo 'Before: sort check history'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) SELECT * FROM benchmark_patrol_before;
\echo 'After: indexed latest timestamp per photo'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) SELECT * FROM benchmark_patrol_after;
