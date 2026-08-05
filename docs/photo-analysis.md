# Photo Analysis

Photo analysis is provider-based, owner-only, and opt-in. Local OpenCLIP runs
inside Docker. Qwen vision calls OpenRouter only after the owner supplies a key
and enables the runtime feature. Restricted photos are excluded from external
analysis.

## Current Status

| System | Status | Purpose | Runtime |
| --- | --- | --- | --- |
| OpenCLIP | Implemented | Semantic image search | Local analysis sidecar |
| YOLO | Scaffolded | Object labels and bounding boxes | Local endpoint currently returns `501` |
| OpenRouter Qwen | Implemented | Editable captions, visual tags, readable text | Dedicated `vision` queue |
| OpenAI Vision | Deferred | Possible future enrichment | Disabled and unconfigured |

Face recognition and automatic identity assignment are intentionally outside
the current scope. People tags remain owner-managed.

## Data Flow

1. A web upload, directory import, or Takeout import creates a normal `Photo`.
2. Metadata and stripped display derivatives are generated locally.
3. Enabled analysis jobs use the display derivative rather than the original.
4. Provider results are versioned in `photo_analysis_runs` and normalized into
   embeddings or tags.
5. Owner search and the photo details panel expose the resulting data.

Analysis feature switches are `AppSetting` values managed from **Repository
Status > Photo Analysis**. Secrets, model choices, budgets, and worker process
shape remain environment settings.

## OpenCLIP

OpenCLIP provides local text-to-image semantic search such as `dog`, `car`,
`landscape`, or `network rack`.

- Rails flag: `analysis_openclip_enabled`
- API key: none
- Source: best available display JPEG
- Runtime: `analysis-local` Docker service
- Output: vectors in the persistent `analysis_index` volume and metadata in
  `photo_embeddings`
- Search: owner text search queries `/openclip/search`, applies normal photo
  visibility rules, and merges visual matches into the result stream
- Details: the owner panel shows model, source derivative, completion time, and
  the latest error

The sidecar keeps its vector matrix in memory and warms it in the background on
startup. Set `OPENCLIP_WARM_ON_START=false` to disable that warmup. Rails caches
semantic query results briefly so returning from a photo to the same search is
fast.

## YOLO

The Rails job, persistence model, feature flag, and sidecar route exist, but
model dependencies and inference are not installed yet. `/yolo/detect` returns
`501` until this phase is implemented. Keep `analysis_yolo_enabled` disabled in
production.

The intended output is normalized `photo_analysis_objects` rows, bounding
boxes, and searchable tags.

## OpenRouter Qwen Vision

Qwen creates an accurate one- or two-sentence caption, up to 12 visual search
tags, and up to 8 representative readable-text snippets. It does not attempt a
full transcription of text-heavy documents, screens, signs, or menus. The
current default is:

```text
qwen/qwen3-vl-30b-a3b-instruct
```

The prompt asks the model to mention visible people, setting, actions, notable
objects, and readable text when present. It explicitly avoids statements about
missing content, speculation, named identification of people, and sensitive
trait inference.

### Privacy

Each request:

- sends a stripped, resized display JPEG rather than the original
- excludes locked/restricted photos
- uses [OpenRouter zero-data-retention routing](https://openrouter.ai/docs/guides/features/zdr)
  with `zdr: true`
- applies [provider data-policy filtering](https://openrouter.ai/docs/guides/routing/provider-selection)
  with `data_collection: deny`
- requires providers that support the requested JSON schema parameters
- does not store the submitted image in the analysis run

The request may include a capture date, camera make/model, and a broad locality
derived from the cached location record. It never includes exact coordinates,
original filenames, Plus Codes, or a new reverse-geocoding lookup. The prompt
also warns that the location is approximate and must not be used by itself to
identify a building, venue, business, or landmark.

Before enabling the feature, review OpenRouter's
[data collection](https://openrouter.ai/docs/guides/privacy/data-collection) and
[input/output logging](https://openrouter.ai/docs/guides/features/input-output-logging)
settings. Keep logging and the data-sharing discount disabled. Use a dedicated
API key with a hard credit limit. The hard key limit is the final billing guard.

### Caption and Search Behavior

The generated description is copied into the normal editable photo caption when
that caption is blank. Owner edits are preserved. A forced regeneration replaces
an untouched prior generated caption, while the generated source remains in
`photo_analysis_runs.summary` for history and search.

Owner search includes:

- the visible editable caption
- completed Qwen summaries
- exact normalized Qwen visual tags
- OpenCLIP similarity results when enabled

The owner photo details panel shows the Qwen model, status, generated text,
visual tags, cost, and latest error.

### OpenRouter Setup

1. Create an OpenRouter account and a dedicated key at
   <https://openrouter.ai/settings/keys>.
2. Put a hard credit limit on that key.
3. Review OpenRouter privacy settings and disable logging/data-sharing options.
4. Add these values to `.env.production` on the Docker host:

```sh
OPENROUTER_API_KEY=sk-or-v1-your-dedicated-key
OPENROUTER_VISION_MODEL=qwen/qwen3-vl-30b-a3b-instruct
OPENROUTER_BUDGET_USD=100
OPENROUTER_ESTIMATED_COST_USD=0.0025
OPENROUTER_MAX_TOKENS=768
VISION_JOB_THREADS=2
```

5. Deploy so the app and worker receive the environment:

```sh
cd ~/apps/photos
./scripts/deploy
```

6. In **Repository Status > Photo Analysis**, enable **OpenRouter Qwen vision
   captions**. Enable **OpenRouter captions for new uploads** when new web and
   directory imports should be captioned automatically.

The app budget is a reservation and monitoring ceiling. It includes every run
with a reported cost, including failed paid attempts. A few requests already in
flight can finish after the ceiling is reached, so the OpenRouter key limit must
remain the hard cap.

### Backfill Existing Photos

Start with a dry run. It reports eligibility and budget capacity without
queueing jobs or spending money:

```sh
docker compose exec -e DRY_RUN=true -e LIMIT=100 worker \
  bin/rails photos:openrouter_backfill
```

Run a 100-photo pilot, inspect the results, and then queue larger bounded
batches:

```sh
docker compose exec -e LIMIT=100 worker bin/rails photos:openrouter_backfill
docker compose exec -e LIMIT=1000 worker bin/rails photos:openrouter_backfill
```

`LIMIT` defaults to 100 and is capped at 50,000. The Repository Status UI offers
25, 100, and 1,000-photo batches. The backfill reserves each selected photo
before enqueueing, so running it again selects the next eligible photos rather
than duplicating paid requests. Qwen backfills are not recurring jobs.

### Run One Photo

Force a fresh Qwen run for one database photo ID:

```sh
docker compose exec worker bin/rails 'photos:qwen[40621]'
```

The task validates that Qwen is enabled, the API key is present, and the photo
is an unlocked still image with an attached original. It queues the work on the
`vision` queue and prints the Active Job ID.

### Monitor and Control the Queue

Repository Status shows completion coverage, pending/running/failed counts,
recorded spend, average completed-photo cost, projected remaining cost, and the
latest errors.

Follow detailed job and provider logs on the server:

```sh
./scripts/logs vision
```

The log includes photo ID, analysis run ID, model, derivative byte size, metadata
context fields, requested token limit, ignored retry providers, request ID,
actual provider, tokens, cost, tags, and failure diagnostics.

Pause or resume the `vision` queue from **Repository Status > Queues**. The CLI
equivalent is:

```sh
docker compose exec worker bin/rails runner \
  'SolidQueue::Queue.find_by_name("vision").pause'
docker compose exec worker bin/rails runner \
  'SolidQueue::Queue.find_by_name("vision").resume'
```

Pausing stops workers from claiming queued jobs and scheduled retries. It does
not cancel a request already in progress. `VISION_JOB_THREADS=2` permits two
simultaneous calls; four is a reasonable next step only after a clean pilot.
Changing thread count requires a worker restart, normally through deploy.

### Retry Behavior

OpenRouter jobs make up to five paid attempts per photo, model, prompt, and
source image for retryable failures:

- network timeouts and connection failures use increasing delays
- HTTP `429` and `5xx` responses honor `Retry-After` when present
- `finish=length` retries with a larger output allowance, up to 1,536 tokens
- empty or malformed completed output retries while temporarily ignoring the
  provider that returned it
- the fifth attempt may preserve a complete caption when only the trailing tags
  or readable-text JSON is malformed

The five-attempt ceiling is enforced from persisted analysis runs, so worker
restarts, duplicate jobs, and later backfill commands cannot reset it. A photo
with a failed current Qwen run is excluded from later automatic backfills.
`photos:qwen[PHOTO_ID]` is the deliberate escape hatch: for an exhausted photo,
it makes one forced call and does not start another retry chain.

Failed runs preserve provider, request ID, finish reason, content size, token
usage, reported cost, and a short response preview when available. A later
success marks earlier failures for the same photo/model/source as recovered
(`skipped`) while retaining their diagnostics and cost.

Useful error interpretations:

- `finish=length`: the provider truncated otherwise valid output; the next
  attempt receives more output tokens.
- `finish=stop bytes=0`: the provider completed with no message content; the
  next attempt routes around that provider.
- malformed JSON with `finish=stop`: a provider returned incomplete structured
  output; the next attempt routes around it.
- `429` or `503`: account/model capacity is temporarily constrained; the job
  waits and retries.

### Start the Qwen Backfill Over

This maintenance procedure removes Qwen analysis history, generated captions,
tags, queued vision jobs, and the app's recorded Qwen spend. It preserves owner
captions that no longer match their generated source. OpenRouter billing records
and actual charges are unaffected.

Stop the worker first, run the cleanup, and deploy to restart it:

```sh
cd ~/apps/photos
docker compose stop worker
docker compose run --rm -T worker bin/rails runner - <<'RUBY'
generated = Photo.where(<<~SQL)
  EXISTS (
    SELECT 1
    FROM photo_analysis_runs runs
    WHERE runs.photo_id = photos.id
      AND runs.provider = 'openrouter'
      AND runs.summary = photos.description
  )
SQL

captions = generated.update_all(description: nil, updated_at: Time.current)
tags = PhotoAnalysisTag.where(provider: "openrouter").delete_all
runs = PhotoAnalysisRun.where(provider: "openrouter").delete_all
jobs = SolidQueue::Job.where(queue_name: "vision").delete_all

puts "Cleared generated captions: #{captions}"
puts "Deleted Qwen tags: #{tags}"
puts "Deleted Qwen runs: #{runs}"
puts "Deleted vision jobs: #{jobs}"
RUBY
./scripts/deploy
```

Run a new dry run before starting another paid backfill.

## Local Analysis Sidecar

The deploy script enables the Compose `analysis` profile, starts the sidecar,
verifies its read-only storage mount, and waits for `/health`. It reuses the
existing `photos-analysis-local:latest` image after the first build. Rebuild it
after sidecar code or dependency changes:

```sh
REBUILD_ANALYSIS=true ./scripts/deploy
```

For manual checks:

```sh
docker compose --profile analysis up -d analysis-local
./scripts/logs analysis
```

The image retains GPU-capable dependencies but runs on CPU when no compatible
GPU runtime is available.

## Data Model

- `photo_analysis_runs`: provider, model, prompt/model version, status, source
  checksum, summary, request diagnostics, token usage, and cost
- `photo_analysis_tags`: normalized provider tags
- `photo_analysis_objects`: future YOLO detections and bounding boxes
- `photo_embeddings`: OpenCLIP vector index metadata

## Future Providers

OpenAI Vision remains deferred because the current Qwen path covers the caption
use case with a lower-cost model and explicit OpenRouter privacy routing. If it
is added later, use a dedicated project/key, stripped display derivatives,
owner confirmation, a tiny pilot, and an explicit policy for private photos.
