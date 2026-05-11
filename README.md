# Photos

Photos is a private-first photo stream and personal archive. It is built with Rails 8, PostgreSQL, Solid Queue, Active Storage, Redis, Google OAuth, Google Drive, and Google Maps.

The app is intentionally closer to a personal Google Photos/Flickr hybrid than a marketing site. The default view is a chronological stream, with albums, locations, maps, archive tools, people tags, and imports supporting that stream without replacing it.

## What It Does

- Displays images and videos from iPhone, Mac, upload, and Google Photos Takeout workflows.
- Preserves originals locally with Active Storage and mirrors originals to Google Drive.
- Generates stripped stream/display derivatives so public viewers do not receive originals or embedded metadata.
- Extracts EXIF, dimensions, capture dates, camera info, and GPS metadata for trusted views.
- Groups the main stream by day and supports infinite scrolling, timeline navigation, and bulk actions.
- Supports private/public albums, shared albums for invited users, and album views that keep photos in the stream.
- Supports an archive stream for screenshots, memes, and other items that should not appear in the main stream.
- Supports map markers, dense location clusters, and `/locations` auto-galleries for geotagged photos.
- Supports public/private visibility for photos and albums, plus an owner-only locked private area.
- Supports invited users, Google login, password login, remember-me sessions, avatars, and owner-managed users.
- Lets the owner tag people in photos. Tagged users can see those photos even when the photo is otherwise private.
- Lets the owner share private albums with invited users without publishing them publicly.
- Imports Google Takeout ZIP archives while preserving album memberships and sidecar metadata.
- Provides an owner-only repository status dashboard for queues, file health, derivative coverage, storage checks, runtime controls, and repository activity notifications.
- Keeps a separate owner-only locked private route for sensitive material.

## Privacy Model

Anonymous visitors only see photos and albums explicitly marked public. They receive display derivatives, not originals, and should not see embedded metadata, archive state, captions, locations, GPS, or original filenames.

Signed-in invited users can see richer details when allowed. They can also see private photos where they are tagged and private albums explicitly shared with them.

Trusted signed-in viewers can use metadata-backed surfaces such as map and locations.

The owner can upload, import, publish, unpublish, archive, restore, tag people, share albums, manage albums, manage users, retry Drive archives, inspect metadata, download originals, and use the locked private route.

## Main Concepts

- **Stream**: the default chronological view of visible photos, grouped by day.
- **Timeline**: right-side stream navigation by month/year.
- **Albums**: manual or imported groupings. Photos remain in the stream when added to albums. Private albums can be shared with invited users.
- **Archive**: owner-only secondary stream for non-photo items that should be hidden from the main stream.
- **Map**: Google Maps view of geotagged photos, with album filtering and clustered markers.
- **Locations**: auto-generated geotagged galleries based on coordinate buckets. Dense map clusters link here.
- **People tags**: owner-managed user tags shown in the photo info panel as avatars. Tags also grant that user access.
- **Drive archive**: Google Drive mirror of originals. It is an archive copy, not the only source of truth.
- **Takeout imports**: Google Photos Takeout ZIP imports for backfilling the library and imported albums.
- **Repository health**: owner-only patrol jobs that read originals, verify size/checksums, report problems, record important activity, and can optionally heal from Drive.
- **App settings**: runtime toggles stored in the database and managed from Repository Status. Environment files are for secrets and deploy wiring, not feature switches.

## Development

Requirements:

- Ruby 3.4.x via rbenv
- PostgreSQL
- libvips
- Google OAuth credentials for sign-in and Drive access
- Optional Google Maps API key for map/location surfaces

Set up local environment variables:

```sh
cp .env.example .env
```

Important development values:

```sh
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
GOOGLE_DRIVE_ARCHIVE_FOLDER_ID=
GOOGLE_MAPS_EMBED_API_KEY=
GOOGLE_MAPS_GEOCODING_API_KEY=
PHOTOS_OWNER_EMAIL=owner@example.com
PHOTOS_TRUSTED_VIEWER_EMAILS=
```

`GOOGLE_MAPS_EMBED_API_KEY` is used in the browser for the map. Reverse geocoding
location names can use a separate server-side `GOOGLE_MAPS_GEOCODING_API_KEY`
with the Google Geocoding API enabled; if it is absent the app falls back to the
embed key.

Then run:

```sh
bin/setup
bin/dev
```

When running Rails commands from automation or a non-interactive shell, prefer
the explicit rbenv form:

```sh
rbenv exec bundle exec rails test
```

Google OAuth redirect URI for local development:

```text
http://127.0.0.1:3000/auth/google_oauth2/callback
```

## Tests And Checks

```sh
rbenv exec bundle exec rails test
rbenv exec bundle exec rubocop
rbenv exec bundle exec brakeman --no-pager
rbenv exec bundle exec rails zeitwerk:check
```

System tests can be run separately when browser coverage is needed:

```sh
rbenv exec bundle exec rails test:system
```

## Production

Production runs as a Docker Compose stack:

- `web`: Rails, Puma, and Thruster exposed on host port `3000`
- `worker`: Solid Queue workers for imports, archive mirrors, metadata, checksums, derivatives, and maintenance
- `db`: PostgreSQL
- `redis`: low-latency Rails cache for hot UI/data reads
- mounted app storage for originals and generated derivatives
- mounted read-only import storage for Google Takeout ZIPs

A reverse proxy terminates TLS and proxies HTTP to the app host on port `3000`.

See [docs/deploy.md](docs/deploy.md) for VM setup, environment files, storage mounts, and backup notes.

## Repository Operations

The owner dashboard at `/repository_status` is the main operational page. It combines:

- queue totals, job classes, workers, and paused queues
- derivative coverage for image and video display assets
- original storage path checks
- latest file health checks and hash fingerprints
- Drive archive/checksum status
- runtime controls for repository maintenance

Runtime controls live in the database via `AppSetting` and are managed from Repository Status. The default seed keeps original file auto-heal disabled:

```sh
docker compose exec web bin/rails db:seed
```

Use the UI to enable auto-heal only when you want failed health checks to enqueue Drive restore jobs. The app intentionally does not use environment variables for this toggle.

Queue a baseline repository scan from `/repository_status` with `Queue baseline scan`, or from the VM:

```sh
docker compose exec web bin/rails runner 'OriginalFileHealthPatrolJob.perform_later(batch_size: 50000, stale_after: 100.years)'
```

Routine patrols are scheduled through Solid Queue recurring jobs. The worker config includes a dedicated `solid_queue_recurring` worker plus bounded queues for imports, archive work, maintenance, analysis, video previews, derivatives, and default jobs.

## Useful Production Commands

Most routine owner operations should be available from `/repository_status`.
The scripts below are deployment helpers, diagnostics, or repair escape hatches
for when the UI is unavailable or a batch needs to be run from the VM.

Deploy on the VM:

```sh
./scripts/deploy
```

Follow logs:

```sh
./scripts/logs
./scripts/logs web
./scripts/logs web worker
```

Open a Rails console:

```sh
docker compose exec web bin/rails console
```

Apply idempotent default app settings:

```sh
docker compose exec web bin/rails db:seed
```

Check import, metadata, derivative, archive, and queue status:

```sh
./scripts/import-status
```

Prewarm missing derivatives:

```sh
./scripts/prewarm-variants
```

Prewarm video thumbnails only:

```sh
./scripts/prewarm-video-previews
```

Queue a bounded batch of missing location names:

```sh
./scripts/geocode-locations 25
```

Prune stale jobs after code/queue changes:

```sh
./scripts/prune-stale-jobs
```

Queue a Google Takeout import from the configured import path:

```sh
docker compose exec web bin/rails runner 'GoogleTakeoutImportJob.perform_later(GoogleTakeoutImportRun.create!(owner: User.find_by!(email: ENV.fetch("PHOTOS_OWNER_EMAIL")), path: ENV.fetch("PHOTOS_TAKEOUT_IMPORT_PATH", "/rails/imports/google-takeout")))'
```

Repository Status is the preferred home for repeatable maintenance controls:
queue patrols, baseline scans, queue pause/resume, auto-heal, derivative
prewarming, location geocoding, failed-job visibility, and safe retry actions.
Low-level repair scripts such as missing-variant cleanup, stale-job pruning,
Takeout metadata repair, and health-state resets should stay CLI-first unless
they are wrapped in explicit owner-only confirmation UI.

## Worker Tuning

Solid Queue worker concurrency is configured with environment variables. Current defaults keep heavy work controlled while allowing derivative generation to use the larger VM:

```sh
IMPORT_JOB_THREADS=1
ARCHIVE_JOB_THREADS=1
MAINTENANCE_JOB_THREADS=1
ANALYSIS_JOB_THREADS=1
DERIVATIVE_JOB_THREADS=3
DEFAULT_JOB_THREADS=1
JOB_PROCESSES=1
```

If the VM shows memory pressure or swap activity, reduce `DERIVATIVE_JOB_THREADS` first.

Queues can be paused and resumed from `/repository_status` for operational control. Worker thread/process counts still come from environment variables because they affect container process shape and require a restart.

## Important Environment Values

Production values live in `.env.production`:

```sh
PHOTOS_HOST=photos.example.com
PHOTOS_ASSUME_SSL=true
PHOTOS_FORCE_SSL=true
PHOTOS_DATABASE_PASSWORD=
PHOTOS_STORAGE_PATH=/mnt/photos/app_storage
PHOTOS_IMPORT_PATH=/mnt/photos/imports
PHOTOS_TAKEOUT_IMPORT_PATH=/rails/imports/google-takeout

GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
GOOGLE_DRIVE_ARCHIVE_FOLDER_ID=
GOOGLE_MAPS_EMBED_API_KEY=
GOOGLE_MAPS_GEOCODING_API_KEY=
PHOTOS_OWNER_EMAIL=owner@example.com
PHOTOS_TRUSTED_VIEWER_EMAILS=
PHOTOS_LOCKED_FOLDER_PASSWORD=
```

`REDIS_URL` is supplied internally by Compose. If it is absent, production falls back to Solid Cache.

Runtime repository controls, such as original file auto-heal, are stored in the app settings table and controlled from `/repository_status`.
