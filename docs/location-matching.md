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
aliases without making unrelated places share an identity. Native-language
matches update automatic names and hierarchy for the same provider identity;
old spellings remain searchable aliases. Places referenced by manual corrections
keep their owner-selected name and hierarchy.

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
rollups prefer an actual locality/postal-town result and its provider ID, verified
against the result's country and local name. This joins translated versions of
the same city without requiring countries such as Latvia to return a county.
Older responses fall back to locality qualified by country, region, and county.
An incomplete hierarchy without a verified city produces ordinary spatial clusters.
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

The index defaults to **Geography**: country alphabetically, then U.S. state,
then city/region/area. Country and state sections stay together as more pages
load. Other countries omit the state level. This is a browsing hierarchy;
country/state headers do not combine or reassign the underlying areas/photos.
Country and state context comes from the saved provider address components,
so enabling this view does not require new API requests. An ambiguous or missing
country goes under Other locations instead of borrowing one from a neighbor.

The **Name** switch shows a flat list ordered by country, U.S. state, then
city/region/area, so Michigan locations stay together even when their city names
differ. The city/area remains the main card label, with country/state underneath
in every view. **Photo count** keeps the largest galleries first; Geography adds
country/state section headings to the same geographic order used by Name.
A one-day gallery displays its date once; multi-day galleries keep a range.
The selected order stays in the URL and is retained when loading more cards.
Namesakes remain separate places in every order.

- `place-id-<id>` identifies one assigned place, independent of its name.
- `region-<hash>` identifies a qualified town/metro overview gallery.
- `city-<hash>` identifies an overview by its verified Google locality ID.
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

When native localization upgrades a region to a verified city, the old region
IDs are retained in the place's provider metadata. Old region links and saved
covers resolve to the new city within the viewer's authorized scope; ambiguous
aliases never silently combine different cities.

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

Response keys describe the request and its API/language contract, never the API
credential. Geocoding v4 responses use a separate native-language namespace;
older cached responses remain saved but cannot establish native naming. Reverse
lookups use six-decimal photo coordinates. Nearby
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
historical landmarks, observation decks, campsites and hiking/natural attractions
within 500 metres; it cannot guarantee
that every photo has a suitable landmark or infer a distant visit.

## Native names and resumable repair

New address/reverse lookups use Google Geocoding v4 without a requested language,
which returns names in the location's native language and script. The server key
still requires Geocoding API access. Nearby Search receives the language from
that native response. Country ISO codes continue to identify U.S. state context
even when the country display name is localized. Complete successful provider
payloads remain in PostgreSQL indefinitely, including fields not currently used.

The ordinary missing-name queue handles unassigned photos. Already assigned
coordinate placeholders need enrichment too. After deploying the new web and
worker code, the resumable repair localizes each existing automatic Google
place once, then enriches unresolved coordinate photos. It preserves manual
edits, provider identities of existing named places, original GPS and EXIF.
Successful searches without a suitable name are recorded and reported rather
than retried forever. Each uncached request allows at most three attempts for
connection/read timeouts, transient connection failures and HTTP 408/500/502/503/504,
with exponential backoff and jitter. Each attempt reserves its cost against the
same cumulative budget before sending, and implicit Net::HTTP retries are disabled.
Provider Retry-After guidance is honored; waits longer than 30 seconds stop the
request rather than retrying early. Permission/quota errors, malformed responses
and an exhausted budget fail immediately; transport errors stop the repair after
the bounded attempts.

From the production checkout, after loading `scripts/lib/compose_env` and calling
`load_compose_env`, run one bounded batch:

```sh
docker compose exec -T worker bin/rails runner 'puts LocationEnrichmentRepair.run!(limit: 100, budget_cents: 5000).to_json'
```

Use `limit: 10000` for a full-library pass, or resume with another bounded batch.
An advisory lock prevents concurrent repairs. Progress and request reservations
survive process restarts in `app_settings`; cached responses cost no new request.
The ceiling is cumulative across batches and cannot be raised above the initial
allowance or $50. It conservatively reserves $0.005 per geocoding attempt and
$0.032 per Nearby attempt before sending, without assuming free monthly usage.
This is an application estimate for this repair, not a Google billing/account cap.
Inspect status without making API requests:

```sh
docker compose exec -T worker bin/rails runner 'puts LocationEnrichmentRepair.status.to_json'
```

An explicitly requested natural area can also be resolved first, for example
`area_query: "Kerlingarfjöll, Iceland", country_code: "IS"`. Only coordinate
photos inside the provider's actual feature bounds qualify, with a 50 km maximum
diagonal. A map viewport is not accepted as a feature boundary. Nearby campsites
outside the mountain bounds are resolved separately by Nearby Search.

Before production repair, retain a protected database backup covering
`photo_places`, `photo_metadata`, `app_settings`, and the response-cache table.
Rollback should restore selected name/assignment fields from that snapshot while
preserving subsequent manual edits and newly cached responses. Do not delete or
reset the budget record to restart a stopped repair.

## Canonical browsing groups

Browsing membership is resolved separately from precise photo-place identity.
`LocationGroupingCatalog` keeps a small, rebuildable canonical catalog in the
database setting `location_grouping_catalog/v1`. It is populated from the saved
native Geocoding v4 responses; complete provider responses remain in their
original permanent cache. Country codes identify one native country label.
Actual locality/postal-town provider IDs identify cities across neighborhoods,
county boundaries and translated address hints.

An otherwise unverified city hint requires matching country/state, an unambiguous
known city and a point within 32 km (about 20 miles). Distant postal towns do not
label landmarks. Such landmarks retain their own names. Missing cities can be
looked up once by qualified city/county/state/country, under the existing repair
budget. Subsequent imports use the saved catalog and native country language.
An omitted provider state is not treated as a conflicting state; known conflicts
still prevent a match. Country, name, distance and uniqueness remain required.
Localities take precedence over postal towns, including when Google returns
separate locality/postal-town IDs for the same UK city. A village's locality also
takes precedence over the larger town in its postal address.

Explicitly requested display areas are also stored in this catalog, with a
provider anchor, country and a bounded radius. The requested Kerlingarfjöll area
uses 16 km (about 10 miles), covering its campsites and nearby highland photos.
This is a browsing rule. It does not assert a provider feature boundary or change
the precise place, GPS, manual correction, or EXIF of any photo.

The grouping repair preserves original provider components separately when it
normalizes country headings or removes unsafe postal hints from display data.
It records old gallery IDs as aliases, retains saved covers, and invalidates only
affected calculated bounds. Precise place names/IDs and photo assignments remain
unchanged, including owner-corrected locations. Stale repair plans skip records
that changed concurrently. Current gallery IDs take priority over historical
aliases when an old group has split.
Valid legacy covers are also copied to the current browsing gallery; the newest
valid choice wins when several older galleries merge. Original cover settings
remain saved, and an explicit current-gallery cover is never overwritten.

After a protected backup, preview the saved-data repair:

```sh
docker compose exec -T worker bin/rails runner 'puts LocationGroupingRepair.run!(apply: false).except(:renamed_groups).to_json'
```

`lookup: true` also resolves missing qualified cities. Its successful responses
and API request reservations are saved even during preview. `apply: true` writes
the derived catalog, grouping descriptors and search aliases. Optional arguments
`area_query: "Kerlingarfjöll, Iceland", area_name: "Kerlingarfjöll"` retain the
requested area. Existing area definitions survive catalog rebuilds. The default
area radius is 16 km, with a maximum of 20 km.

Include `photo_places`, `photo_metadata`, `app_settings`,
`location_geocoding_responses`, saved covers and calculated bounds in the backup.
Verify photo coordinates/assignments, manual metadata and precise place fields
against it after repair. Recovery restores only the affected derived place
fields, with review for subsequent edits; retain newly cached responses and the
cumulative budget record.

## Verification

Regressions cover namesakes, several venues in one cell, one place across cells,
coordinate rounding, delayed jobs, manual re-extraction, legacy link choices,
stale covers, access revocation, more than 500 places, and region zoom changes.
Browser tests exercise real map endpoints and popups with a stubbed Google map;
they do not verify live provider responses or real-world boundary accuracy.
