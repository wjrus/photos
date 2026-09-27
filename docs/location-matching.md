# Location matching and map grouping

Photos have an explicit `photo_metadata.photo_place_id` assignment. A
`PhotoPlace` represents the geographic feature returned by the provider, or an
exact coordinate when the response cannot identify a suitable feature. A
display name and a map cluster are never used as photo-place identity.

This replaces the earlier model that assigned one name to each 0.025-degree
grid cell and merged every cell with an equal name. That model allowed a manual
address to rename neighboring photos and combined distant namesakes.

## Matching rules

Reverse geocoding chooses a result whose own type and provider ID identify a
specific geographic feature: a neighborhood, sublocality, locality/postal town,
or smaller administrative division. A street-address result's ID is not used
for a locality name extracted from its address components. A POI is accepted
automatically only when its point matches the stored coordinate at six decimal
places. Manual address selection can deliberately assign an address or venue.

The canonical key is `google:<feature place_id>`. Incomplete, ambiguous,
county-only, and Plus Code results use `coordinate:<latitude6>,<longitude6>`.
No nearby-coordinate probes are made. Broader returned names remain searchable
aliases without making unrelated places share an identity. Later matches of
the same provider feature add aliases and fill missing map-region information
while preserving its established display name and complete region descriptor.

Manual edits update only the selected photos in a transaction. Background
matching rechecks coordinates and assignment state after the provider request,
so a late response cannot replace a newer correction. Metadata re-extraction
preserves manual coordinates and provenance. Changed assignments invalidate
affected saved bounds; location cards reject covers that have moved elsewhere.

## Map zoom levels

At zoom **10 and below**, a qualified city/metro region may combine several
places into one marker. At higher zoom, markers use the detailed locations and
spatial clustering. Region grouping changes map presentation only: it does not
change photo assignments, location pages, covers, or exact place filters.

When the provider's address components identify Greater London within the
United Kingdom, the map label is **London**. This uses administrative membership,
not the wider commuter belt. Other city
rollups require a locality qualified by country, region, and county. An
incomplete hierarchy produces ordinary spatial clusters without a city label.
These rollup keys are distinct from canonical place IDs.

Clusters containing several precise locations offer zooming, without linking
to one representative photo's place. City clusters zoom to at least level 11.
All counts, previews, and bounds use the current viewport, filters, and viewer's
authorized photos. Identical labels in different qualified regions remain
separate.

## URLs and existing data

- `place-id-<id>` identifies one assigned place, independent of its name.
- `area-<latitude_bucket>_<longitude_bucket>` contains only unmatched photos in
  that cell. Matching a photo moves it out of this temporary group.
- Old numeric cell URLs still describe the geographic cell, including assigned
  photos. They retain coordinate titles rather than borrowing a venue name.
- Old `place-<encoded name>` URLs redirect when there is one visible candidate,
  or show a choice when several places match. They never silently combine
  namesakes into one location feed.

Existing `photo_location_places` records are retained as legacy name-to-cell
history for old-link resolution. They are not evidence for assigning every
photo in that cell to a new place. Existing covers are retained and reused only
when the cover still belongs to the current place/area. Places and aliases do
not grant access to photos.

## Applying the transition

The schema changes are additive. The existing metadata-table index is built
concurrently, with foreign-key/check validation in a separate migration. Apply
both migrations before starting the new web and worker code; roll back code
before removing the new schema. Old queued cell-geocoding jobs are harmless
no-ops under the new worker.

The migrations do not call Google or guess a backfill from old grid names.
Initially, old unassigned photos appear in coordinate areas. After deploying,
run controlled batches through Repository Status or:

```sh
./scripts/geocode-locations 100
```

Each batch restores explicit legacy manual assignments from their saved
per-photo address data, then queues unmatched automatic photos. It defaults to
100 and accepts a maximum of 1,000; `all` is deliberately unsupported. Exact
coordinate response caching and the existing one-request-per-second throttle
limit repeated requests. Provider charges can still apply to new coordinates.
Inspect progress and provider usage before queuing another batch.

```sh
./scripts/geocode-locations --refresh 100
```

Refresh revisits eligible automatic assignments without deleting saved places
or modifying manual corrections. It starts with the least recently updated
metadata; successful matches advance that timestamp even when their assignment
is unchanged. Wait for the queued photo jobs to finish before requesting the
next batch. Failed lookups stay eligible for retry, and batches do not continue
automatically. Raw coordinates and legacy records remain available throughout
the transition. Bounds refresh continues through the existing maintenance job.

## Verification

Regressions cover namesakes, several venues in one cell, one place across cells,
coordinate rounding, delayed jobs, manual re-extraction, legacy link choices,
stale covers, access revocation, more than 500 places, and region zoom changes.
Browser tests exercise real map endpoints and popups with a stubbed Google map;
they do not verify live provider responses or real-world boundary accuracy.
