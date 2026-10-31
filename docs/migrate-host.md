# Moving Photos to another host

Use `scripts/migrate-host` on the current production server. It transfers the
existing library, databases, queue, analysis indexes, model downloads, secrets,
and exact source revision. Nothing is re-imported or re-analyzed. Google Drive
archive state and existing Rails signing/encryption keys are preserved.

This procedure expects the documented Docker Compose deployment, PostgreSQL 18,
the `photos` Compose project, and a clean `main` checkout. It does not migrate
other applications on the source server. It never copies live PostgreSQL data
files, changes DNS, prunes Docker resources, or runs `scripts/deploy`.

## Prepare the destination

Use an updated Ubuntu LTS VM with Docker Engine and its Compose plugin from
[Docker's official repository](https://docs.docker.com/engine/install/ubuntu/).
The target needs Bash, Git, rsync, coreutils, util-linux/flock, and SSH. The
administrator account needs Docker access and noninteractive sudo for the
receiver's rsync and empty-directory checks. Docker access already grants
root-equivalent privileges. Protect this account's SSH key accordingly.

Default target paths are:

| Purpose | Path |
| --- | --- |
| Application | `/home/wjr/apps/photos` |
| Migration state and protected payload | `/home/wjr/photos-migration` |
| Originals, derivatives, exports, uploads | `/mnt/photos/app_storage` |
| Import inputs | `/mnt/photos/imports` |

Create the application and migration directories owned by the SSH user, mode
750 or stricter. Create storage/import directories owned by **UID/GID 1000**, the
Rails container account, with readable/traversable parents. The SSH user's UID
does not need to be 1000; the rsync receiver uses sudo and assigns the container's
ownership. Keep these directories empty for the first preflight. The tools refuse
to adopt a pre-existing installation or nonempty data directories.

Set `MIGRATION_TARGET_APP`, `MIGRATION_TARGET_STATE`,
`MIGRATION_TARGET_STORAGE`, and `MIGRATION_TARGET_IMPORTS` to override defaults.
Use canonical absolute paths without spaces or shell characters. Their final
components must remain `apps/photos`, `photos-migration`, `app_storage`, and
`imports`, respectively. File names inside the library may contain spaces.

Configure SSH key authentication **from the old server to the new user** and
verify the destination host key before adding it to known_hosts. The scripts use
strict host-key checking and never copy private SSH keys. `MIGRATION_SSH_PORT`
defaults to 22. On the new VM, use key-only SSH, an incoming firewall allowing
SSH/HTTP/HTTPS, Docker log rotation, and a host TLS reverse proxy.

Docker-published ports can bypass UFW. The target build writes a private,
untracked `compose.override.yml` that binds port 3000 to **127.0.0.1 only**.
The host reverse proxy forwards to that address; PostgreSQL, Redis, and analysis
are not published. See [Docker's firewall documentation](https://docs.docker.com/engine/network/packet-filtering-firewalls/).
An example host proxy configuration is in
[`config/nginx/host.conf.example`](../config/nginx/host.conf.example).

## Preflight and live transfer

On the old server, from its production checkout:

```sh
./scripts/migrate-host preflight wjr@new.example.com
./scripts/migrate-host sync wjr@new.example.com
```

The scripts can also live outside the production checkout. Set
`MIGRATION_APP_ROOT` to the checkout and preserve the tools' `scripts/lib/`
layout. This avoids changing a deployed checkout just to install migration tools.
Run long transfers in tmux/screen or another persistent session so disconnecting
your laptop does not cancel the server-to-server copy.

Preflight inventories database totals and actual container mounts, checks SSH,
and initializes the empty destination with an ownership marker. `sync` performs
resumable rsync transfers while the current site keeps running, then exports a
rehearsal snapshot. Repeat it to reduce the final delta. A source file disappearing
during an active transfer can cause rsync to fail; rerun `sync` after that activity
settles. Only the dedicated, marked target storage/import paths are mirrored
with deletion. Source files are never deleted.

Import inputs are copied by default. Use `MIGRATION_COPY_IMPORTS=0` only if they
are expendable and no pending job or future import needs them. Use the same value
throughout the migration. Relative in-container paths remain `/rails/imports`
and `/rails/storage`, even if host paths change.

Snapshots use a private directory outside the checkout, defaulting to
`~/photos-migration-source`, and are removed locally after successful transfer
or ordinary failure. An interrupted process killed with SIGKILL can leave a
private `snapshot.*` directory; inspect it before removing it. Allow workspace
for all four database dumps and model/index archives. Snapshots contain secrets
and private data: do not put them in Git, attach them to issues, or publish logs.
Keep the source state directory between runs: its identity binds subsequent
transfers to the initialized destination.

On the new server, prebuild the source release:

```sh
bash ~/photos-migration/run build
```

This restores the checkout from a Git bundle, installs environment files and
credential keys with mode 600, and builds the app/analysis images. It starts no
Photos services and makes no provider requests through Rails. The sidecar's
Hugging Face and Torch caches are redirected into the persistent model volume.
The source's existing `/models` volume and container download cache are both
captured, because earlier deployments may store weights in the container layer.

The online database snapshot is for preparation only. The tool deliberately
refuses to restore it as a final migration. Verify the rsync totals, available
disk space, import inputs, and backups before scheduling downtime. The tools
check minimum workspace; these checks do not replace planning capacity and
long-term growth headroom.

## Final write freeze and restore

Lower DNS TTL ahead of time. Stop external uploaders/automation, avoid deploys
and administrative writes, and arrange any desired maintenance page at the old
public reverse proxy. Schedule downtime before running:

```sh
# OLD server: this intentionally stops the old Photos site and its workers.
./scripts/migrate-host final-sync --confirm-stop-source wjr@new.example.com
```

The tool checks target readiness before stopping Photos ingress/web containers,
allows workers up to 15 minutes to stop, and then stops analysis. PostgreSQL and
Redis remain running for export. Other Compose projects remain untouched.
It copies the final file delta and exports primary, queue, cache, and cable
databases with `pg_dump -Fc`. It checks for source code changes and container
starts during the freeze, compares file metadata after transfer, and verifies
the payload's SHA-256 manifest on the destination.

**The source stays stopped on success or failure.** A failed final transfer
does not silently restart it or mark the target complete. Diagnose and rerun the
final transfer, or explicitly abandon the migration and restart the source.
Do not start two writable installations.

For a complete byte comparison before starting any target services:

```sh
# OLD server; reads every transferred file, so budget time for the source disk.
./scripts/migrate-host verify wjr@new.example.com
```

On the new server:

```sh
# Reuses build layers and applies the FINAL revision/configuration.
bash ~/photos-migration/run build
bash ~/photos-migration/run restore
bash ~/photos-migration/run verify
```

Restore starts only PostgreSQL and Redis. It restores each empty database in a
single transaction with error checking, installs both analysis volumes, and
compares photo/blob/attachment counts and attached byte totals with the source.
It preserves existing queue contents. Completed database restores have receipts
so a retry can skip them; a populated database without a receipt or an unexpected
existing analysis volume requires investigation. The script never drops a
database, clears a queue, or overwrites an existing analysis volume to make a
retry succeed. Transfers are blocked once restoration has started.

If restore fails, keep both web/worker installations stopped. Inspect the error
and target state before retrying. Keep the payload until migration acceptance;
do not remove partial databases/volumes without confirming the exact target.

## Verify web, then cut over

```sh
# NEW server: starts analysis and web on loopback; workers remain stopped.
bash ~/photos-migration/run web
```

This checks for pending migrations without applying them. A migrated copy of the
exact running release should have none. Check the local health endpoint, then
test through the new TLS proxy using a local hostname override or `curl --resolve`.
If the new proxy does not yet have a valid certificate for the production name,
arrange DNS-based certificate validation beforehand, or budget the HTTP-based
issuance step into cutover. Check login, albums, original downloads, variants,
video playback, semantic search, and any existing photobook exports. Compare
storage totals and confirm provider flags/credentials without submitting orders
or re-enabling backfills as a test. Do not use `scripts/deploy` for this private
verification because it starts workers and pulls new code.

Once the new proxy is ready, update **both A and AAAA records as applicable**,
complete/verify TLS, and confirm public requests reach the new VM. Remove the
new proxy's staging/maintenance response only when ready. Then:

```sh
MIGRATION_ENABLE_WORKERS=1 bash ~/photos-migration/run activate
```

Only then resume uploaders and background processing. Keep the source frozen
through DNS propagation. Requests still reaching it should see maintenance or
be forwarded deliberately to the new installation, never a writable old copy.

The restored Git remote points to the original source-control remote. Provision
a dedicated deploy key or other appropriate GitHub access before using normal
`scripts/deploy` in future; the migration does not copy source private keys.
Public repositories can use HTTPS read access instead. Review provider API-key
IP restrictions and allow the new server's outbound addresses where required.
Retain off-host backups, the old installation, and the protected migration
payload until acceptance. After new writes begin, rollback is a data-reconciliation
operation, not just a DNS reversal.
