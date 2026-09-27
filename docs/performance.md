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

## Aggregate caches and access

Map markers, location rows, album index payloads, and timeline aggregates use
the existing caches for owners. Viewer and anonymous requests recompute these
aggregates from the current visible scope. People-tag changes, album membership
changes, and same-second publication changes therefore take effect immediately,
without retaining private titles, coordinates, dates, or counts in a stale
payload. This trades repeated aggregate queries for reliable access revocation
outside the owner account; owner cache hits remain unchanged.

Persisted location bounds summarize the owner's full visible library, so only
owner map requests reuse them. Viewer map bounds are computed from the photos
the viewer can currently access, including when focusing a named place.
`AggregateCacheAccessTest` exercises grants, revocations, and publication changes
with a real memory cache, plus a named place containing a hidden distant photo.

## Search navigation

Search navigation stores at most 10,000 ordered photo IDs, fetched without
instantiating photo records or preloading attachments. Subsequent pages reuse the
same snapshot for up to 30 minutes when its audience and query match. A new
search or full result-page refresh rebuilds its IDs, including when returning
from the viewer after editing a result. This keeps navigation aligned with newly
matching, renamed, archived, or deleted photos. Cursor and stream-page fragments
reuse the snapshot without querying all result IDs; changing filters or an
expired cache entry rebuilds it. Refreshing an empty result clears its previous
snapshot. Photo visibility is still checked on each page and viewer request.
The snapshot grants no access to photos.

`PhotoSearchOrderSnapshotTest` checks bounded results, zero record instantiation,
zero photo queries when reusing a snapshot, explicit refresh, expiry, changed
filters, and audience isolation. Controller regressions cover navigation after
result mutations and snapshot reuse for older/newer/stream-page fragments.

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

Location page fragments skip summary aggregation. Browsing does not enqueue
geocoding. The full page still prepares its heading, counts, map,
and timeline. Regression tests check that both coordinate and named-location
fragments execute no aggregate queries, that an exhausted page remains valid,
and that an inaccessible coordinate location still returns 404.

## Feed and map media loading

Cards and map markers preload a read-only metadata projection containing only
the photo ID, dimensions, coordinates, and assigned place ID. They no longer fetch the full EXIF
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

## Indexed place and coordinate filters

Resolved places filter by the indexed `photo_metadata.photo_place_id`, so a
venue never needs to claim every photo in its coordinate cell. Place names and
aliases are matched through a subquery; only the selected photos are loaded.
Location pages count and paginate groups in SQL, with no implicit 500-place
cutoff. A 501-place regression loads only 12 place records for the first page.
The map's compact selector keeps the top 500 locations plus a selected location
outside that list. Search menu coordinates summarize only the viewer's visible photos.

Unmatched areas and old coordinate links express each cell as half-open latitude
and longitude ranges. The old `FLOOR(coordinate / 0.025) = bucket` predicates
required computing buckets across the table. The ranges use the existing
coordinate index. Bounds use decimal
arithmetic with exact-edge adjustments to preserve persisted Float-derived
place IDs. Regression tests cover exact boundaries, missing coordinates, invalid
IDs, multi-cell places, and visibility restrictions.

```sh
psql -X -d photos_test -v ON_ERROR_STOP=1 -f test/performance/location_filter.sql
```

With 100,000 synthetic metadata rows, a local run on September 26, 2026 produced:

| Filter | Computed buckets | Indexed ranges | Matching rows |
| --- | ---: | ---: | ---: |
| One coordinate cell | 17.584 ms | 0.044 ms | 24 |
| Two coordinate cells | 15.767 ms | 0.101 ms | 48 |

The computed-bucket plans scanned all 100,000 rows. The ranges used an index scan and
bitmap index scans respectively. These are isolated query timings, not complete
place-page response times. These timings apply to coordinate filtering; resolved
place pages now use the direct foreign-key lookup described above.

Unmatched-area grouping, map cells, and coordinate-bound maintenance use the same
floating-point buckets as old coordinate URLs. Since GPS columns store six
decimal places, indexed range endpoints advance by one microdegree when Float
rounding assigns the exact boundary to the preceding cell. For example,
latitude `44.775000` belongs to bucket `1790`, so its upper bound is
`44.775001`. This keeps coordinate filters and area links consistent without
wrapping indexed columns in functions.
Regression checks cover every geographic cell boundary and its adjacent stored
coordinates, plus named-place search, map links, and bounds refreshes. Cached
location/map results use new namespaces; assignment changes invalidate affected
bounds, and the existing maintenance job rebuilds them. See
[location matching](location-matching.md) for place identity, legacy links, and
zoom-dependent metropolitan grouping.

Only metadata containing both latitude and longitude participates in locations,
maps, bounds, geocoding, and place menus. Partial EXIF coordinates remain stored,
but cannot create phantom locations or collide with the valid `0_0` cell.

## Private feed pagination

The unlocked Private feed uses the same 60-item cursor pagination as the other
feeds, including older/newer loading and returning to a focused photo. The
heading still reports the full item count. Previously every private photo and
its thumbnail associations loaded on the initial request. A 123-photo regression
now renders 60 cards initially and checks complete forward/backward traversal
without duplicates, including tied and missing capture dates. Page fragments
remain subject to the owner and folder-unlock checks.
