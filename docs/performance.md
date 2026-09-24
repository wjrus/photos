# Performance checks

## Photo stream queries

The descending stream and viewer neighbors use the same indexed tuple:
capture-date presence, normalized capture date, creation date, and ID. Photos
without a capture date remain last, and creation date/ID break ties. The SQL
expressions in `Photo` and the cursor indexes must stay aligned. PostgreSQL can
then seek directly to either side of a cursor and stop after one page, including
when navigating back from an undated photo.

The earlier indexes used `captured_at DESC` (implicitly `NULLS FIRST`), while the
feed requested `DESC NULLS LAST` and neighbor queries ordered by another
expression. Those differences caused full scans and sorts even with `LIMIT`.
See [PostgreSQL index ordering](https://www.postgresql.org/docs/18/indexes-ordering.html).

Run the repeatable synthetic benchmark against a local scratch database:

```sh
psql -X -d photos_test -v ON_ERROR_STOP=1 -f test/performance/photo_stream.sql
```

It creates a temporary table containing 100,000 synthetic photos with duplicate
timestamps and missing capture dates. It compares the old and new first-page,
deep-page, and neighbor query plans. No application tables are changed. Look for
an index scan with only the requested rows visited and no sort. These database
timings exclude rendering, image I/O, network latency, and production load.

The original indexes remain useful for oldest-first album queries, so the
migration retains them alongside the new cursor indexes. The benchmark also
checks that chronological ordering can still use its original index.

A representative local run with 100,000 synthetic rows produced these query
execution times (milliseconds; not end-to-end page timings):

| Query | Before | After |
| --- | ---: | ---: |
| First 61-photo page | 13.422 | 0.022 |
| Deep 61-photo page | 6.413 | 0.025 |
| Previous photo | 13.636 | 0.006 |

The new plans visit 61, 61, and 1 rows respectively without a sort. The retained
oldest-first index also serves a 61-photo page without sorting (0.021 ms in that
run). Actual timings depend on hardware, data distribution, cache warmth, and
concurrent work; inspect the plans as well as the timings.

Timeline aggregates discard media preloads so computing counts/date ranges does
not join Active Storage attachments and variant records.

## Search navigation

Search navigation stores at most 10,000 ordered photo IDs, fetched without
instantiating photo records or preloading attachments. Subsequent pages reuse the
same snapshot for up to 30 minutes when its audience and query match. A new
search without a token creates a fresh snapshot; changing filters or an expired
cache entry rebuilds it. Photo visibility is still checked on each page and
viewer request. The snapshot grants no access to photos.

`PhotoSearchOrderSnapshotTest` checks bounded results, zero record instantiation,
zero photo queries when reusing a snapshot, expiry, changed filters, and audience
isolation.

## Text search association matches

Text search tests album and people membership with ID subqueries. Joining both
collections used to multiply each candidate photo by its album count times its
people count, even though the outer query ultimately returned unique photos.
Matching album and user IDs also stay in SQL instead of requiring two separate
queries and Ruby arrays. Visibility restrictions and escaped search terms remain
part of the query; anonymous searches still only search photo titles.

Run the focused synthetic benchmark:

```sh
psql -X -d photos_test -v ON_ERROR_STOP=1 -f test/performance/photo_search.sql
```

It creates temporary tables with 100,000 photos, six album memberships and four
people tags per photo, and verifies identical result sets before measuring. One
local run reduced the ordered-ID query from **794.361 ms to 28.521 ms** (about
28 times faster). The old plan generated 2.4 million candidate rows and spilled
temporary data to disk; the new plan scanned 100,000 photos and used indexed
membership lookups without that spill. This isolates association matching and
excludes metadata/semantic search, rendering, media I/O, and production load.
It is not an end-to-end search latency claim.

## Album covers and location scrolling

Album cover selection caches IDs without instantiating photos or loading their
attachments. Only the requested page's covers are then loaded for rendering.
A cold-cache regression with 25 albums (mixed explicit and automatic covers)
reduced first-page Photo instantiations from **50 to 12**; subsequent pages load
12 and 1 respectively. Automatic covers still use the newest visible photo when
an explicit cover is inaccessible.

Location page fragments skip summary aggregation and coordinate-summary
geocoding work. The full page still prepares its heading, counts, map,
and timeline. Regression tests check that both coordinate and named-location
fragments execute no aggregate queries, that an exhausted page remains valid,
and that an inaccessible coordinate location still returns 404.

## Feed and map media loading

Cards and map markers preload a read-only metadata projection containing only
the photo ID, dimensions, and coordinates. They no longer fetch the full EXIF
JSON payload. The ordinary `metadata` association still loads all fields for
the viewer, editing, and background jobs.

Feed preloads explicitly include the attachments needed to render thumbnails;
they omit video playback blobs and Active Storage preview trees that the card
does not use. Map payloads load only the video-preview attachment's presence,
with no original blobs or variant records. Still-image map previews use the
existing 700-pixel stream derivative instead of the 1800-pixel display
derivative, sharing URLs with feed thumbnails. Video previews also go through
the authorized stream endpoint.

Run the reproducible media-loading benchmark in the test environment:

```sh
RAILS_ENV=test rbenv exec bundle exec rails runner test/performance/media_preloads.rb
```

The script creates 40 images with two variants each and 20 videos with preview
and playback attachments. Each photo has 50 KB of synthetic EXIF. It rolls all
database changes back and writes no media files. A local run produced:

| Media preload | Queries before | Queries after | Active Record objects before | Objects after |
| --- | ---: | ---: | ---: | ---: |
| Feed page, 60 items | 16 | 8 | 560 | 500 |
| Map previews, 60 items | 12 | 3 | 520 | 140 |

Both paths also avoid fetching 3,001,320 bytes of synthetic raw EXIF in that
fixture. These counts describe the media preloading stage, not the entire HTTP
request. Actual metadata sizes and photo/video mixes vary.

Marker requests also skip full-page location menus and selected-location
summaries, including on cache hits and for clients without a JSON Accept header.
The selected location's visibility is still checked. Tests cover cached coordinate
and named locations, video readiness, full metadata access, and rendering
preloaded thumbnails without extra SQL queries.
