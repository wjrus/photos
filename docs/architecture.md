# Photos Architecture

`photos` is a private-first Rails photo stream for William Rockwood / wjr.us.

## Starting Choices

- Ruby 3.4.9 and Rails 8.1.3.
- PostgreSQL for relational data.
- Rails Active Storage for originals and derivatives.
- Solid Queue for background work and Solid Cache for Rails cache to start.
- Google OAuth as the first and only login provider.
- Google Drive as an archive mirror for preserved originals, checksums, and future manifest data.
- Tailwind for the UI so the app can feel custom without carrying a heavy frontend stack.

## Development Google Setup

- `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` power Google sign-in.
- `GOOGLE_DRIVE_ARCHIVE_FOLDER_ID` points at the Drive folder that receives original archive mirrors.
- `PHOTOS_OWNER_EMAIL` marks William's Google account as the initial owner account.
- Local OAuth callback URL: `http://localhost:3000/auth/google_oauth2/callback`.

## Privacy Model

- New photos should be private by default.
- Anonymous users may only see explicitly public display derivatives.
- Anonymous users must never receive originals, EXIF, GPS, or embedded metadata.
- Authenticated/invited users may receive richer detail based on access grants.
- Notes, people tags, EXIF panels, and maps are privileged surfaces.

## Background Jobs

Workers are part of the core app, not an afterthought:

- Generate display derivatives.
- Strip metadata from public derivatives.
- Extract EXIF/GPS into structured database records for authorized views.
- Compute checksums for originals.
- Mirror originals to Google Drive.
- Verify Drive archive copies against local checksums.

## Early Domain Shape

- `User`: Google-authenticated person.
- `Photo`: preserved original plus publication state.
- `PhotoVariant`: generated derivative metadata.
- `PhotoMetadata`: EXIF/GPS and camera data.
- `PersonTag`: private/invited people tags.
- `Note`: owner-authored notes.
- `AccessGrant`: invite and visibility permissions.
- `DriveArchiveObject`: Google Drive mirror state and checksum verification.
