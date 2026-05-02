# Deploy

Production is a small Docker Compose stack:

- `web`: Rails, Puma, Thruster, HTTP on host port `3000`
- `worker`: Solid Queue worker for checksums, EXIF, derivatives, and Drive mirrors
- `db`: PostgreSQL with persistent data
- `app_storage`: persistent Active Storage originals and variants

The Postgres volume is mounted at `/var/lib/postgresql`, which is the expected layout for the official PostgreSQL 18+ Docker image.

Nginx Proxy Manager should terminate TLS for `photos.wjr.us` and proxy to:

```text
http://<vm-ip>:3000
```

## First Setup

Copy the example environment file on the VM:

```sh
cp .env.production.example .env.production
cp .env.postgres.example .env.postgres
```

Fill in every blank value. `.env.postgres` `POSTGRES_PASSWORD` and `.env.production` `PHOTOS_DATABASE_PASSWORD` should be the same value for this Compose stack.

Required Google OAuth redirect URI:

```text
https://photos.wjr.us/auth/google_oauth2/callback
```

Build and start:

```sh
docker compose build
docker compose up -d
```

The `web` container runs `bin/rails db:prepare` on boot. That creates and migrates the primary, cache, queue, and cable databases.

Check status:

```sh
docker compose ps
docker compose logs -f web
docker compose logs -f worker
```

Open a Rails console:

```sh
docker compose exec web bin/rails console
```

## Updates

```sh
git pull
docker compose build
docker compose up -d
```

## Backups

Back up both named volumes:

- `photos_postgres_data`
- `photos_app_storage`

The database contains users, photo records, metadata, jobs, and Drive archive state. `app_storage` contains originals and generated local files. Google Drive is an archive mirror, not the only source of truth.

## Nginx Proxy Manager

Use a Proxy Host:

- Domain: `photos.wjr.us`
- Forward Hostname/IP: VM IP
- Forward Port: `3000`
- Scheme: `http`
- Websockets: enabled
- SSL certificate: Let's Encrypt
- Force SSL: enabled in Nginx Proxy Manager

Rails also treats requests as SSL when `PHOTOS_ASSUME_SSL=true` and uses secure cookies/redirects when `PHOTOS_FORCE_SSL=true`.
