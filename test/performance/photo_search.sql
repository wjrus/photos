-- Run with: psql -X -d photos_test -v ON_ERROR_STOP=1 -f test/performance/photo_search.sql
-- Session-local synthetic data only. Isolates the album/people row multiplication
-- in text search; excludes semantic search, metadata, rendering, and image I/O.
CREATE TEMP TABLE benchmark_photos (id bigint PRIMARY KEY, title text);
CREATE TEMP TABLE benchmark_albums (id bigint PRIMARY KEY, title text);
CREATE TEMP TABLE benchmark_users (id bigint PRIMARY KEY, name text);
CREATE TEMP TABLE benchmark_memberships (photo_id bigint, photo_album_id bigint);
CREATE TEMP TABLE benchmark_tags (photo_id bigint, user_id bigint);

INSERT INTO benchmark_photos
SELECT n, CASE WHEN n % 1000 = 0 THEN 'Synthetic expedition' ELSE 'Synthetic scene' END
FROM generate_series(1, 100000) n;
INSERT INTO benchmark_albums
SELECT n, CASE WHEN n = 1 THEN 'Synthetic expedition album' ELSE 'Synthetic album' END
FROM generate_series(1, 1000) n;
INSERT INTO benchmark_users
SELECT n, CASE WHEN n = 1 THEN 'Synthetic expedition person' ELSE 'Synthetic person' END
FROM generate_series(1, 1000) n;
INSERT INTO benchmark_memberships
SELECT n, (n + offset_id) % 1000 + 1
FROM generate_series(1, 100000) n CROSS JOIN generate_series(1, 6) offset_id;
INSERT INTO benchmark_tags
SELECT n, (n + offset_id) % 1000 + 1
FROM generate_series(1, 100000) n CROSS JOIN generate_series(1, 4) offset_id;

CREATE UNIQUE INDEX ON benchmark_memberships (photo_album_id, photo_id);
CREATE INDEX ON benchmark_memberships (photo_id);
CREATE UNIQUE INDEX ON benchmark_tags (photo_id, user_id);
CREATE INDEX ON benchmark_tags (user_id);
ANALYZE benchmark_photos;
ANALYZE benchmark_albums;
ANALYZE benchmark_users;
ANALYZE benchmark_memberships;
ANALYZE benchmark_tags;

-- Previously the application looked up matching album/user IDs separately.
-- Their cost is excluded from the old query below, favoring the baseline.
CREATE TEMP VIEW benchmark_before AS
SELECT photos.* FROM benchmark_photos photos WHERE photos.id IN (
  SELECT candidate.id FROM benchmark_photos candidate
  LEFT JOIN benchmark_memberships memberships ON memberships.photo_id = candidate.id
  LEFT JOIN benchmark_albums albums ON albums.id = memberships.photo_album_id
  LEFT JOIN benchmark_tags tags ON tags.photo_id = candidate.id
  LEFT JOIN benchmark_users users ON users.id = tags.user_id
  WHERE candidate.title ILIKE '%expedition%' OR albums.id IN (1) OR tags.user_id IN (1)
);

CREATE TEMP VIEW benchmark_after AS
SELECT photos.* FROM benchmark_photos photos WHERE photos.id IN (
  SELECT candidate.id FROM benchmark_photos candidate
  WHERE candidate.title ILIKE '%expedition%'
    OR candidate.id IN (
      SELECT photo_id FROM benchmark_memberships WHERE photo_album_id IN (
        SELECT id FROM benchmark_albums WHERE title ILIKE '%expedition%'
      )
    )
    OR candidate.id IN (
      SELECT photo_id FROM benchmark_tags WHERE user_id IN (
        SELECT id FROM benchmark_users WHERE name ILIKE '%expedition%'
      )
    )
);

-- Validate equivalent result sets and warm both query paths before measuring.
DO $$
BEGIN
  IF EXISTS (
    (SELECT id FROM benchmark_before EXCEPT SELECT id FROM benchmark_after)
    UNION ALL
    (SELECT id FROM benchmark_after EXCEPT SELECT id FROM benchmark_before)
  ) THEN
    RAISE EXCEPTION 'Search result sets differ';
  END IF;
END $$;

\echo 'Before: ordered search IDs with six albums and four people per photo'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id FROM benchmark_before ORDER BY id DESC LIMIT 10000;

\echo 'After: ordered search IDs using membership subqueries'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id FROM benchmark_after ORDER BY id DESC LIMIT 10000;
