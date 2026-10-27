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
places. When no neighborhood or town result exists, a named natural feature or
tourist attraction returned within 500 metres can name its immediate vicinity;
an actual feature boundary must also contain the photo when provided. Manual
address selection can deliberately assign an address or venue.

The canonical key is `google:<feature place_id>`. Incomplete, ambiguous,
county-only, and Plus Code results use `coordinate:<latitude6>,<longitude6>`.
Normal reverse matching makes no nearby-coordinate probes; explicit landmark
refreshes can additionally use Places Nearby Search as described below.
Broader returned names remain searchable
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
change photo assignments or exact place filters. The Locations overview uses
the same qualified city identities to offer broader browsing galleries.

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

The Locations index summarizes towns and city areas rather than listing every
coordinate or venue separately. Saved provider address components also supply
town membership for older assignments. Greater London is shown as London.
Different towns in the same county remain separate. Incomplete town hierarchies
include a geographic guard so distant namesakes do not merge.

Coordinate-only assignments without a qualified town share a 0.125-degree cell
(about 8.6 miles north/south; longitude width varies by latitude). This is a
bounded fallback, not a radius or a chain of nearby points. A Plus Code suffix
such as Grand Canyon Village can label the group when its hints agree; bare
codes become a readable Nearby coordinate label. Fixed cell boundaries can
split nearby unknown points; API town membership joins them across cells.

Opening an overview area shows all its authorized photos. Its Map link filters
to those photos and retains their original GPS points and normal zoom-dependent
marker groups. Overview grouping never changes the underlying assignments.

The index defaults to photo count, largest first. Its Name switch
orders named areas alphabetically, followed by unmatched coordinate areas.
The selected order stays in the URL and is retained when loading more cards.
Namesakes remain separate places in either order.

- `place-id-<id>` identifies one assigned place, independent of its name.
- `region-<hash>` identifies a qualified town/metro overview gallery.
- `nearby-<latitude_bucket>_<longitude_bucket>` identifies a fallback overview cell.
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

The mobile API's location listing continues to expose precise place IDs. Broad
overview IDs are accepted by the existing photo and map filters.

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

## Durable API responses and landmark refreshes

`photo_places` already retains selected provider data and assigned names.
`location_geocoding_responses` additionally saves complete successful reverse,
address, and Nearby Search responses in PostgreSQL without a TTL. This additive
migration must run before the updated web and workers start. Existing places
are preserved; their selected raw result cannot reconstruct an entire past API
response, so the first lookup at a previously uncached request may still call
Google once. Database backups should include the new table.

Response keys describe the request, never the API credential or the matching
algorithm version. Reverse lookups use six-decimal photo coordinates. Nearby
searches share rounded three-decimal search points and recheck each candidate
against the actual photo GPS. Empty successful results are saved as well;
permission, quota, transport, and malformed-response errors are not cached.
Clearing Redis/Rails.cache or deploying new matching logic does not repeat a
saved request. A normal refresh reprocesses saved responses; it does not force
new provider data or expire saved responses.

In **Repository status → Files**, use **Refresh location names** with **Improve
nearby landmark names with Google Places** checked. A batch includes at most
100 photos. Only otherwise unresolved coordinate/small administrative matches
use Places Nearby Search; ordinary scheduled matching does not enable it.
Manual corrections and original GPS remain protected. Wait for completion
before queuing another batch, and inspect failed jobs for provider errors.

Enable **Places API (New)** and allow it in the server key's API restrictions.
The lookup reuses `GOOGLE_MAPS_GEOCODING_API_KEY` by default, or accepts a
dedicated `GOOGLE_MAPS_PLACES_API_KEY`. Nearby Search requests only Pro-tier
fields and may incur additional Google charges. It considers named attractions,
historical landmarks and observation decks within 500 metres; it cannot guarantee
that every photo has a suitable landmark or infer a distant visit.

## Verification

Regressions cover namesakes, several venues in one cell, one place across cells,
coordinate rounding, delayed jobs, manual re-extraction, legacy link choices,
stale covers, access revocation, more than 500 places, and region zoom changes.
Browser tests exercise real map endpoints and popups with a stubbed Google map;
they do not verify live provider responses or real-world boundary accuracy.
