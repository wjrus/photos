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
