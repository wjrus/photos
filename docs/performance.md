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

Timeline aggregates discard media preloads so computing counts/date ranges does
not join Active Storage attachments and variant records.
