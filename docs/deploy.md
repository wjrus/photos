# Deploy

Production is a small Docker Compose stack:

- `app_proxy`: local nginx router on host port `3000`
- `web_blue` / `web_green`: Rails, Puma, and Thruster app backends
- `worker`: Solid Queue worker for checksums, EXIF, derivatives, and Drive mirrors
- `analysis-local`: private local OpenCLIP/YOLO analysis sidecar
- `db`: PostgreSQL with persistent data
- `redis`: Redis cache for hot Rails cache entries
- `app_storage`: persistent Active Storage originals and variants

The Postgres volume is mounted at `/var/lib/postgresql`, which is the expected layout for the official PostgreSQL 18+ Docker image.

A reverse proxy should terminate TLS for your configured `PHOTOS_HOST` and proxy to:

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

For production storage on the Unraid mount, set this in `.env.production`:

```sh
PHOTOS_STORAGE_PATH=/mnt/photos/app_storage
```

Required Google OAuth redirect URI:

```text
https://photos.example.com/auth/google_oauth2/callback
```

Build and start:

```sh
./scripts/deploy
```

The deploy script runs `bin/rails db:prepare` before switching web traffic. That creates and migrates the primary, cache, queue, and cable databases without adding migration time to the web restart window. Redis is used for the runtime Rails cache when `REDIS_URL` is present; Solid Cache remains available as a fallback.

The deploy script also enables the Compose `analysis` profile, builds
`analysis-local`, starts it before Rails workers, verifies the storage mount, and
waits for its `/health` check. Provider feature flags still default off in the
app, so deploying the sidecar does not start broad analysis by itself.

Deploys use a blue/green app backend behind the local `app_proxy` service:

1. Build the new app image.
2. Start the inactive app backend, either `web_blue` or `web_green`.
3. Wait for that backend's `/up` healthcheck to pass.
4. Reload `app_proxy` so Nginx Proxy Manager continues to hit host port `3000`, but traffic moves to the new backend.
5. Stop the old backend after the proxy switch.

The first deploy after enabling blue/green removes the old legacy `web` container so `app_proxy` can bind port `3000`; later deploys should only have a short proxy reload blip.

Check status:

```sh
docker compose ps
./scripts/logs
```

Open a Rails console:

```sh
docker compose exec worker bin/rails console
```

## Updates

```sh
./scripts/deploy
```

The deploy script exports `PHOTOS_STORAGE_PATH` from `.env.production` before invoking Docker Compose, verifies that app, worker, and analysis containers mount that exact path at `/rails/storage`, and waits for the new app backend healthcheck to pass before switching `app_proxy`.

If you need to run Docker Compose directly, export the storage path first:

```sh
export PHOTOS_STORAGE_PATH=/mnt/photos/app_storage
docker compose up -d
```

## Backups

Back up the database volume and the app storage path:

- `photos_postgres_data`
- `photos_redis_data`
- `${PHOTOS_STORAGE_PATH}`

The database contains users, photo records, metadata, jobs, and Drive archive state. Redis contains disposable cache entries. `${PHOTOS_STORAGE_PATH}` contains originals and generated local files. Google Drive is an archive mirror, not the only source of truth.

## Nginx Proxy Manager

Use a Proxy Host:

- Domain: your configured `PHOTOS_HOST`
- Forward Hostname/IP: VM IP
- Forward Port: `3000`
- Scheme: `http`
- Websockets: enabled
- SSL certificate: Let's Encrypt
- Force SSL: enabled in Nginx Proxy Manager

Rails also treats requests as SSL when `PHOTOS_ASSUME_SSL=true` and uses secure cookies/redirects when `PHOTOS_FORCE_SSL=true`.
