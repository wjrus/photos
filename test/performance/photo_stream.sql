-- Run with: psql -X -d photos_test -v ON_ERROR_STOP=1 -f test/performance/photo_stream.sql
-- Only a session-local temporary table is populated; application data is untouched.
CREATE TEMP TABLE benchmark_photos (
  id bigint PRIMARY KEY,
  captured_at timestamp,
  created_at timestamp NOT NULL,
  restricted boolean NOT NULL,
  archived_at timestamp,
  title text
);

INSERT INTO benchmark_photos
SELECT n,
  CASE WHEN n % 20 = 0 THEN NULL ELSE TIMESTAMP '2000-01-01' + (n / 5) * INTERVAL '1 hour' END,
  TIMESTAMP '2026-01-01' + n * INTERVAL '1 second',
  false, NULL, repeat('Synthetic photo ', 10)
FROM generate_series(1, 100000) n;

CREATE INDEX benchmark_original_order ON benchmark_photos (captured_at DESC, created_at DESC, id DESC)
WHERE restricted = false AND archived_at IS NULL;
ANALYZE benchmark_photos;

\echo 'Before: first page'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM benchmark_photos WHERE restricted = false AND archived_at IS NULL
ORDER BY captured_at DESC NULLS LAST, created_at DESC, id DESC LIMIT 61;

\echo 'Before: deep page'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM benchmark_photos WHERE restricted = false AND archived_at IS NULL AND (
  captured_at < TIMESTAMP '2000-06-15 16:00:00' OR
  (captured_at = TIMESTAMP '2000-06-15 16:00:00' AND created_at < TIMESTAMP '2026-01-01 05:33:21') OR
  (captured_at = TIMESTAMP '2000-06-15 16:00:00' AND created_at = TIMESTAMP '2026-01-01 05:33:21' AND id < 20001) OR
  captured_at IS NULL
)
ORDER BY captured_at DESC NULLS LAST, created_at DESC, id DESC LIMIT 61;

\echo 'Before: previous neighbor'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM benchmark_photos WHERE restricted = false AND archived_at IS NULL AND
  (CASE WHEN captured_at IS NULL THEN 0 ELSE 1 END, COALESCE(captured_at, TIMESTAMP '0001-01-01'), created_at, id) >
  (1, TIMESTAMP '2000-06-15 16:00:00', TIMESTAMP '2026-01-01 05:33:21', 20001)
ORDER BY CASE WHEN captured_at IS NULL THEN 0 ELSE 1 END ASC, captured_at ASC NULLS FIRST, created_at ASC, id ASC LIMIT 1;

CREATE INDEX benchmark_cursor ON benchmark_photos (
  (CASE WHEN captured_at IS NULL THEN 0 ELSE 1 END) DESC,
  COALESCE(captured_at, TIMESTAMP '0001-01-01') DESC, created_at DESC, id DESC
) WHERE restricted = false AND archived_at IS NULL;
ANALYZE benchmark_photos;

\echo 'After: first page'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM benchmark_photos WHERE restricted = false AND archived_at IS NULL
ORDER BY CASE WHEN captured_at IS NULL THEN 0 ELSE 1 END DESC,
  COALESCE(captured_at, TIMESTAMP '0001-01-01') DESC, created_at DESC, id DESC LIMIT 61;

\echo 'After: deep page'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM benchmark_photos WHERE restricted = false AND archived_at IS NULL AND
  (CASE WHEN captured_at IS NULL THEN 0 ELSE 1 END, COALESCE(captured_at, TIMESTAMP '0001-01-01'), created_at, id) <
  (1, TIMESTAMP '2000-06-15 16:00:00', TIMESTAMP '2026-01-01 05:33:21', 20001)
ORDER BY CASE WHEN captured_at IS NULL THEN 0 ELSE 1 END DESC,
  COALESCE(captured_at, TIMESTAMP '0001-01-01') DESC, created_at DESC, id DESC LIMIT 61;

\echo 'After: previous neighbor'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM benchmark_photos WHERE restricted = false AND archived_at IS NULL AND
  (CASE WHEN captured_at IS NULL THEN 0 ELSE 1 END, COALESCE(captured_at, TIMESTAMP '0001-01-01'), created_at, id) >
  (1, TIMESTAMP '2000-06-15 16:00:00', TIMESTAMP '2026-01-01 05:33:21', 20001)
ORDER BY CASE WHEN captured_at IS NULL THEN 0 ELSE 1 END ASC,
  COALESCE(captured_at, TIMESTAMP '0001-01-01') ASC, created_at ASC, id ASC LIMIT 1;

\echo 'Retained: oldest-first album ordering'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM benchmark_photos WHERE restricted = false AND archived_at IS NULL
ORDER BY captured_at ASC NULLS LAST, created_at ASC, id ASC LIMIT 61;
