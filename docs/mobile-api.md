# Mobile API v1

The API lives under `/api/v1` on each independently hosted Photos installation.
It supports an Ionic/Capacitor client with a photo grid, full-screen viewer,
swipe navigation, swipe-up information/map sheet, albums, archive, locked folder,
bulk editing, and original backup. Discover compatibility using
`GET /api/v1/capabilities` before presenting login.

The server implements data and authorization contracts. Gestures, native maps,
AirPlay presentation, photo-library discovery, background scheduling, and
Face ID/Touch ID belong to the mobile client. See
[mobile app feasibility](mobile-app-feasibility.md) for platform constraints.

## Requests, responses, and access

- Use trusted HTTPS. API paths and media paths are relative to the configured
  installation URL. Do not send an installation's credentials to another host.
- Send `Accept: application/json`; send JSON bodies as `application/json`, except
  binary upload endpoints, which use `application/octet-stream`.
- Authenticate using `Authorization: Bearer <access_token>`. Browser cookies are
  not accepted as API credentials. No broad CORS policy is enabled: use native
  HTTP when connecting from a Capacitor app to independent hosts.
- JSON responses use `Cache-Control: private, no-store`. Store any offline cache
  explicitly in the app and isolate it by server and account.
- Errors have the form `{"error":{"code":"not_found","message":"Resource not found."}}`.
  Expect 400 for malformed input, 401 for missing/expired credentials, 403 for
  disallowed operations, 404 for inaccessible resources, 409 for upload/state or
  derivative-readiness conflicts, 422 for validation/action failures, and 429
  for throttling. Media can additionally return 206 or 416 for byte ranges.
- Owners manage their own photos, albums, and uploads. Other signed-in users
  can browse public photos and photos granted through tags or shared albums.
  Archived and locked-folder collections are owner-only. Metadata and maps
  require an owner or an accepted invitation. These are the desktop access rules.
- General photo and album reads exclude archived and restricted photos. Request
  the appropriate collection explicitly. A restricted resource is inaccessible
  until this device separately unlocks the folder.
- JSON timestamps are ISO 8601. IDs are database integers. Fields may be null;
  clients must tolerate additional response fields in future compatible releases.

## Per-device authentication

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/capabilities` | Public API version, features, action lists, and limits |
| POST | `/session` | Password login and registration of a device session |
| POST | `/session/refresh` | Rotate access and refresh tokens |
| DELETE | `/session` | Revoke the current device session |
| GET | `/me` | Current user and permission flags |
| GET | `/devices` | This account's device sessions, including revoked sessions |
| DELETE | `/devices/:id` | Revoke one of this account's device sessions |

Paths in the tables omit the `/api/v1` prefix. Login body:

```json
{
  "email": "alice@example.com",
  "password": "synthetic-example-password",
  "device_name": "Alice's phone",
  "platform": "ios"
}
```

`device_name` is required, up to 100 characters. `platform` is `ios`, `android`,
or `other`. Success is 201 with `access_token`, `refresh_token`, `token_type`,
`expires_at`, `refresh_expires_at`, `device_id`, and `user` (`id`, `name`, `role`).
Secrets are returned only when issued; the database retains their SHA-256 digests.
Login is limited by IP and normalized email. A Google-only account must establish
a password through the existing web password-reset/invitation flow first.

Access tokens last up to 30 days. Refresh tokens expire 90 days after the device
session was created; refresh does not extend that absolute deadline. Refresh with
`{"refresh_token":"<refresh_token>"}`. Success is 200 with a replacement token
pair and deadlines. The previous pair immediately becomes invalid, including
replay of the old refresh token. Serialize refresh requests and persist the new
pair together. If the response is lost after rotation, sign in again.

Revocation and account password changes invalidate the device. Permissions use
the account's current role and grants. `/me` reports `manage_library`, `upload`,
`metadata`, and `restricted_unlocked`. Device listing accepts `limit` (default
60, clamped to 1–100) and `before_id`; it returns `devices`, `has_more`, and
`next_before_id`. Device records include name, platform, timestamps, and a
`current` flag; no token digests are exposed.

### Face ID and Touch ID

The server authenticates a device token, not a biometric result sent by the app.
Store credentials in native secure storage and use the platform's biometric
authentication to control interactive access. Never transmit biometric data or
use an app-supplied boolean as proof of identity.

An important client policy decision is whether credentials can be read by native
background work while the app is locked. Requiring biometric user presence for
every credential read prevents unattended backup. Keep interactive unlocking and
background credential access policies explicit; token revocation still works for
both. See [Apple Local Authentication](https://developer.apple.com/documentation/localauthentication).
There is no browser device-code approval flow in this API.

## Browsing and swipe navigation

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/photos` | A bounded page of photo/video summaries |
| GET | `/photos/:id` | Summary, description when permitted, and visible albums |
| GET | `/photos/:id/navigation` | Previous and next photos in the same context |
| GET | `/photos/timeline` | Month/count groups for the selected context |
| GET | `/photos/:id/info` | Curated metadata and location for an information sheet |
| PATCH | `/photos/:id` | Owner edit of `photo.title` and/or `photo.description` |
| DELETE | `/photos/:id` | Owner permanently deletes a photo and its original |

Shared browsing parameters:

| Parameter | Meaning |
| --- | --- |
| `collection` | `library` (default), `public`, `archive`, or `restricted` |
| `album_id` | Restrict to photos in an accessible album |
| `q` | Text search using the existing Photos search fields |
| `camera_make`, `camera_model`, `lens_model`, `person_id`, `place_id` | Existing search filters |
| `media_type` | `image` or `video` |
| `captured_after`, `captured_before` | ISO 8601 capture time; inclusive lower and exclusive upper bound |
| `order` | `stream` or `chronological`; defaults to chronological in an album, otherwise stream |
| `limit` | Page size, default 60, clamped to 1–100 |
| `cursor` | Opaque photo cursor returned by the API |
| `direction` | `next` (default) or `previous` |

Search filters are capped at 500 bytes each. Search uses deterministic lexical/
metadata matching, including album/person/place and stored analysis text/tags;
it does not invoke semantic embedding search. Preserve the same filters and
order on every pagination, detail, information, and navigation request.

`stream` sorts capture dates newest first, puts undated photos last, and breaks
ties with creation time and ID. `chronological` sorts capture dates oldest first,
also puts undated photos last, and uses the same tie breakers. `/photos` returns
`photos`, `order`, `direction`, `has_more`, `next_cursor`, and `previous_cursor`.
`has_more` describes the requested direction; cursors are boundary anchors, not
promises that another page exists. Do not decode or synthesize cursors. Ordering
can change if a background metadata job changes capture time; refresh the grid
to reconcile those updates.

A photo summary includes ID, title, media type, timestamps, dimensions, cursor,
visibility/archive/restricted state, media paths, and permission flags. Video
thumbnail/playback paths are null while derivatives are pending. Detail adds
visible album IDs/titles and the description when metadata access is allowed.

For the viewer, request `/photos/:id/navigation` with the current context. It
returns `photo_id`, `order`, `previous`, and `next`; either neighbor can be null.
Use these summaries to prefetch the adjacent image. After a bulk action removes
photos from the context, reconcile the grid and neighbors; successful bulk
responses do not return a desktop redirect.

Timeline returns `periods` containing `month` (`YYYY-MM`) and `count`, newest
first. It groups capture time, falling back to creation time for undated photos,
using the database's timestamp convention. Capture-time filters exclude undated
photos; clients should handle undated items separately when jumping by month.

## Swipe-up information sheet and maps

`/photos/:id/info` returns `photo_id`, `filename`, `byte_size`, `content_type`,
`description`, `metadata`, `location`, `people`, and `processing`.

Metadata is an allowlist: extraction status, capture date, width/height, camera
make/model, lens, exposure, aperture, ISO, focal length, video duration/codecs/
container/frame rate/bitrate, and location source. Raw EXIF/provider payloads,
internal error messages, storage paths, and archive credentials are not returned.
Processing flags describe checksum status, metadata status, and video readiness.

When coordinates exist, `location` supplies numeric `latitude`, `longitude`,
optional place `name`, and `location_id`. Otherwise it is null. The native client
can show a map marker in the swipe-up sheet, without receiving a server-side map
API key. People entries contain tag ID, user ID, and display name.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/map` | Paginated photo markers in the browsing context |
| GET | `/locations` | Grouped accessible places/areas with counts |
| GET | `/people` | Owner's tag target list |
| POST | `/photos/:photo_id/people_tags` | Owner tags `user_id` |
| DELETE | `/photos/:photo_id/people_tags/:id` | Owner removes a tag |

`/map` accepts browsing filters and optional `north`, `south`, `east`, `west`.
Provide all four bounds or none. Latitude is within ±90 and longitude within
±180; east less than west represents crossing the antimeridian. Response has
`markers` (photo summary, coordinates, location ID), `next_cursor`, and
`has_more`. Cluster/render markers in the native map; this endpoint does not
return map tiles or a cluster hierarchy.

`/locations` accepts `collection`, `page` (starting at 1), and `limit`; it returns
`locations`, `page`, and `has_more`. Groups include ID, title, count, coordinates,
and a filtered `photos_path`. `/people` accepts `after_id` and `limit`, returning
`people`, `has_more`, and `next_after_id`.

## Albums and bulk operations

| Method | Path | Body / purpose |
| --- | --- | --- |
| GET | `/albums` | Accessible albums; `page` and `limit` pagination |
| GET | `/albums/:id` | Album summary and filtered photos path |
| POST | `/albums` | `{"album":{"title":"Synthetic trip","visibility":"private"}}` |
| PATCH | `/albums/:id` | `album.title` and/or `album.visibility` |
| DELETE | `/albums/:id` | Delete album; retain its photos |
| POST | `/albums/:id/photos` | Add `photo_ids` |
| DELETE | `/albums/:id/photos` | Remove `photo_ids`; repair the cover if needed |
| PUT | `/albums/:id/cover` | Exactly one `photo_ids` entry already in the album |
| POST | `/albums/bulk` | `bulk_action` (`publish`, `unpublish`, `delete`) and `album_ids` |
| POST | `/photos/bulk` | `bulk_action`, `photo_ids`, and action-specific arguments |
| GET | `/photo_books` | Owner's available photobook targets; `before_id` and `limit` |
| POST | `/photo_books` | Create a target with `{"title":"Synthetic book"}` |

Album list responses include `albums`, `page`, and `has_more`. Summaries contain
ID, title, visibility, update time, accessible photo count, accessible cover
summary, and `manage`. Counts/covers are computed with batched queries and never
include photos hidden from the current user. Albums sort by title then ID.

Bulk selections must contain 1–200 positive integer IDs; duplicates are removed.
Every requested ID must be manageable by the owner or the entire operation fails
with 404 before mutation. Changes are transactional. The photo action service is
shared with the desktop controller. Use **`bulk_action`**, not `action`, because
`action` is a reserved Rails routing parameter.

| Photo bulk action | Additional parameters / behavior |
| --- | --- |
| `publish`, `unpublish` | Set public/private visibility |
| `archive`, `restore` | Move into/out of archive; preserve originals and album membership |
| `restrict` | Move to locked folder; clear publication and archive state |
| `unrestrict` | Requires this device's folder unlock; return to private library |
| `delete` | Permanently delete selected photos |
| `add_to_album` | `album_id` or `new_album_title`; duplicate memberships are skipped |
| `remove_from_album` | `context_album_id`; repair removed cover references |
| `set_album_cover` | `context_album_id`; exactly one accessible member photo |
| `add_to_photo_book` | `photo_book_id` or `new_photo_book_title`; existing/ineligible photos skipped |
| `set_location` | `location_address`; use configured server geocoder; skip non-images |

Successful photo operations return `action`, `affected_count`, `skipped_count`,
and `message`, plus `album_id` or `photo_book_id` when relevant. Album bulk returns
`action` and `affected_count`. State edits can also target archived photos. Locked
photos require the separate unlock even for mutation. This API exposes all
desktop photo/album bulk operations; it does not expose the photobook layout
editor or infrastructure/admin operations.

## Locked-folder access

`POST /restricted_access` with `{"password":"<folder password>"}` unlocks the
current owner's device for 15 minutes and returns `unlocked_until`. This uses
the server's existing `PHOTOS_LOCKED_FOLDER_PASSWORD`, independently of account
login. `DELETE /restricted_access` locks the device again. A failed attempt clears
its unlock, and attempts are throttled. Changing the configured folder password
invalidates existing unlocks. Native biometric unlocking of the app does not
automatically grant folder access.

Read locked photos with `collection=restricted`. Metadata and media requests
still require current access; signed links do not bypass a lock or unlock expiry.

## Media, video playback, and AirPlay

Photo summaries return bearer-authenticated media paths:

- `/photos/:id/media/thumbnail`: stripped JPEG thumbnail or video preview.
- `/photos/:id/media/display`: stripped display JPEG for still images.
- `/photos/:id/media/video`: generated playable video, once available.
- `/photos/:id/media/original`: preserved original, owner-only.

These endpoints stream bounded storage chunks. Single HTTP byte ranges and suffix
ranges are supported for video seeking or downloads. Multiple/unsatisfiable
ranges return 416. Requests are authorized before serving bytes, including HEAD.
Unavailable video derivatives return 409 with `media_pending`.

For a receiver/player that cannot send bearer headers, request:

```http
POST /api/v1/photos/123/media_url
Authorization: Bearer <access_token>
Content-Type: application/json

{"variant":"video","expires_in":3600}
```

Response is `{"url":"<signed URL>","expires_at":"<ISO 8601 timestamp>"}`.
Allowed variants are `thumbnail`, `display`, `video`, and owner-only `original`.
Lifetime defaults to 600 seconds; `expires_in` can be 60–3600 seconds. Supply the
browsing context when issuing a URL for archived or locked photos.

A link is bound to one device, photo, and variant. Each HTTP request rechecks
device revocation/password validity, current photo visibility/grants, and locked
folder access. A transfer already authorized is not interrupted mid-response;
subsequent requests must still pass authorization. Refresh links before expiry,
especially for long videos or later seek requests. Treat signed URLs as temporary
credentials and redact query strings in reverse-proxy/access logs.

The server provides media delivery, not an AirPlay receiver/control protocol.
Use native iOS external-display presentation for still-photo slideshows with
independent phone browsing, and native media playback/routing for video. See
[Apple connected displays](https://developer.apple.com/documentation/uikit/presenting-content-on-a-connected-display).
Native hardware behavior remains to be validated by the future mobile app.

## Durable backup uploads

Uploads are private, owner-only, and scoped to the issuing device session. Persist
the upload ID and manifest locally. Raw transfers do not rely on browser cookies,
multipart form construction, or the lifetime of an Ionic JavaScript task.

| Method | Path | Purpose |
| --- | --- | --- |
| POST | `/uploads` | Create/recover an upload from its manifest |
| GET | `/uploads` | This device's receipts/pending uploads; `before_id` and `limit` |
| GET | `/uploads/:id` | Status, received chunk positions, and final photo |
| PUT | `/uploads/:id/file` | Raw whole file; validate and finalize automatically |
| PUT | `/uploads/:id/chunks/:position` | Raw zero-based fixed-size chunk |
| POST | `/uploads/:id/complete` | Assemble and finalize a chunked/staged upload |
| DELETE | `/uploads/:id` | Cancel/delete staging or a receipt; retain an imported photo |

Create with:

```json
{
  "upload": {
    "client_asset_id": "synthetic-device-asset-v1",
    "filename": "synthetic.png",
    "content_type": "image/png",
    "byte_size": 12345,
    "checksum_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "captured_at": "2026-10-04T12:00:00Z"
  }
}
```

The example checksum and size are placeholders: calculate both from the actual
original bytes. All fields except `captured_at` are required. The filename must
be plain, without path separators/control characters, and at most 255 characters.
Content type must identify an image/video. Asset IDs are up to 200 characters;
include an asset revision when its bytes change. SHA-256 is 64 lowercase hex
characters. Original content is also subject to existing Photo validation.

First creation returns 201; repeating an identical device/asset manifest returns
200 and the existing upload. Reusing an asset ID with another manifest returns
409 `asset_conflict`. Uploads last seven days from creation. They support files
up to 8 GiB, 8 MiB chunks, and at most 1,000 active uploads per device. Creation
is throttled to 120 requests/minute per device. Queue bounded batches on the phone.
If an expired receipt still exists before the next cleanup run, delete that
receipt and recreate the manifest to restart the same asset ID immediately.

The `upload` response contains ID, client asset ID, filename, size, checksum,
chunk size/count, received chunk positions, expiry, completion timestamp,
`duplicate`, and the final photo summary/detail when accessible. After completion,
received chunks are empty because staging is removed. A final photo can be null
if it was subsequently deleted or is currently locked. Listing adds `has_more`
and `next_before_id`.

### Whole-file background upload

Create the manifest in advance, then schedule a native file-backed HTTP PUT to
`/uploads/:id/file` with a bearer token and the original bytes. By default, the
server verifies, imports, and finalizes in that same request; the native app need
not wake JavaScript to issue a second completion call. A repeated PUT after
completion returns the receipt without creating another photo.

Use `?complete=false` only when deliberately staging a file for a later explicit
completion. Body size must exactly match the manifest. A lost response is
recoverable through status or an idempotent completion retry.

### Chunked upload

Send each chunk with exactly 8 MiB of data, except the last, which has the exact
remaining size. Re-sending a position replaces that chunk. Fetch status and skip
already received positions after an interruption. Completion requires every
position and verifies byte size and SHA-256 before creating a photo; incomplete
or corrupt uploads return 400. Completed receipts make repeated completion safe.

Deduplication checks the actual verified checksum across the owner's originals,
including uploads from another device, before importing. Imports through this API
are serialized per owner during the duplicate check. This is exact-byte
deduplication, not visual similarity, and does not add a global uniqueness rule
to desktop/importer uploads. Photos remain private and retain normal checksum,
metadata, derivative, and archive background processing. Optional capture time
can subsequently be reconciled by existing metadata extraction.

The hourly `CleanupMobileUploadsJob` removes expired staging and receipts without
deleting imported photos. Cancellation does the same. When a device is revoked,
its API requests fail; sign in again and start new manifests with the new device
session. An identical original is deduplicated on completion.

### Native and server integration considerations

- Library scanning, iCloud original downloads, permissions, retry scheduling,
  Wi-Fi/cellular policy, and upload queue persistence remain client work.
- This API accepts raw PUTs and its own chunk protocol. It does **not** implement
  Apple's newer PhotoKit extension/resumable HTTP draft negotiation. The arbitrary
  host restriction discussed in the feasibility document remains unresolved.
- Configure the deployment's request-size/time limits for the chosen transfer
  strategy. Whole-file import currently verifies and assembles synchronously;
  large videos need sufficient proxy timeouts and staging disk space. Native
  clients should recover by status after a timeout rather than assuming failure.
- Deleting an asset from the phone does not delete its server copy. Server deletion
  is an explicit authenticated operation. Live Photo resource pairing and edit
  reconstruction are not modeled by v1; upload resources separately if preserving
  their bytes, and do not claim a reconstructed Live Photo experience.

## Installing and verifying the server change

The migration adds device sessions and upload/chunk tables; no existing photo
tables are rewritten. Apply the normal application migration during an authorized
release. Keep the maintenance queue running for staging attachment cleanup and
the normal photo pipeline. No new service or gem dependency is required.

Focused checks:

```sh
PARALLEL_WORKERS=1 rbenv exec ruby bin/rails test \
  test/controllers/api/v1/mobile_api_test.rb \
  test/controllers/photo_bulk_actions_controller_test.rb
rbenv exec ruby bin/rubocop
rbenv exec ruby bin/brakeman --no-pager
```

API integration coverage exercises token rotation/replay/revocation, access
boundaries, contextual navigation, maps/info privacy, locked-folder access,
scoped media URLs and ranges, bulk parity, durable upload retries, checksums,
deduplication, and cleanup. Native biometric, AirPlay, and iOS background behavior
require separate testing in the eventual app.
