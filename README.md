# Photos

Photos is William Rockwood's personal photo stream and archive, built with Rails 8, PostgreSQL, Solid Queue, Active Storage, Google OAuth, Google Drive, and Google Maps.

The app is intentionally closer to a private Flickr/Google Photos hybrid than a marketing site. The primary view is a chronological photo stream. Albums, maps, captions, invitations, and archival state support the stream without replacing it.

## What It Does

- Imports and displays images and videos from iPhone/Mac workflows, including HEIC, JPG, PNG, MOV, MP4, and Apple AAE sidecars.
- Preserves originals and generates stripped display derivatives for public viewing.
- Mirrors originals to a Google Drive archive folder with checksum/archive state.
- Extracts photo metadata and dimensions for trusted viewers.
- Shows Google Maps for geotagged photos, including album-filtered maps.
- Supports public/private photo and album visibility.
- Supports owner-created users, invitation links, password login, Google login, remember-me sessions, and avatar uploads.
- Lets the owner tag people in photos. Tagged users can see those photos even when the photo is otherwise private.
- Imports Google Takeout archives into the stream while preserving album membership.
- Keeps a separate owner-only private route for sensitive imported material.

## Privacy Model

Anonymous visitors only see photos and albums explicitly marked public. They receive display copies, not originals, and should not see embedded metadata, archive information, captions, locations, or original filenames.

Signed-in invited users can see richer details and map/location information. They can also see private photos where they are tagged.

The owner can upload, import, publish, unpublish, tag people, manage albums, retry Drive archives, inspect metadata, download originals, and remove photos.

## Main Concepts

- **Stream**: the default chronological view of visible photos.
- **Albums**: optional groupings. Photos remain in the stream even when added to albums.
- **Map**: a geotagged photo map. It defaults to all visible photos and can filter to a visible album.
- **People tags**: owner-managed user tags shown in the photo info panel as avatars. Tags also grant tagged users access to that photo.
- **Drive archive**: a Google Drive mirror of originals. Local app storage remains part of the source of truth.
- **Takeout imports**: Google Takeout ZIP imports can backfill historical Google Photos exports and albums.

## Development

Requirements:

- Ruby 3.4.x via rbenv
- PostgreSQL
- libvips
- Google OAuth credentials for sign-in and Drive access
- Optional Google Maps Embed API key for maps

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
PHOTOS_OWNER_EMAIL=wjr@wjr.us
```

Then run:

```sh
bin/setup
bin/dev
```

Google OAuth redirect URI for local development:

```text
http://127.0.0.1:3000/auth/google_oauth2/callback
```

## Tests

```sh
bin/rails test
bin/rails test:system
bin/rubocop
```

## Useful Production Commands

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

Open a Rails console in production:

```sh
docker compose exec web bin/rails console
```

Run a Google Takeout import from the default import path:

```sh
docker compose exec web bin/rails runner 'GoogleTakeoutImportJob.perform_later(GoogleTakeoutImportRun.create!(owner: User.find_by!(email: ENV.fetch("PHOTOS_OWNER_EMAIL")), path: ENV.fetch("PHOTOS_TAKEOUT_IMPORT_PATH", "/rails/imports/google-takeout")))'
```

## Deployment

Production runs as a Docker Compose stack with:

- `web`: Rails/Puma/Thruster exposed on host port `3000`
- `worker`: Solid Queue worker for checksums, metadata, imports, and Drive archive jobs
- `db`: PostgreSQL
- `redis`: Rails cache
- mounted app storage for originals and generated files

Nginx Proxy Manager terminates TLS for `photos.wjr.us` and proxies HTTP to the VM on port `3000`.

See [docs/deploy.md](docs/deploy.md) for the VM setup, environment files, storage mount, and backup notes.
