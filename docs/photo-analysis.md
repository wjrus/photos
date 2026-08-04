# Photo Analysis Plan

Photo analysis is intentionally provider-based and opt-in. Local processors run
first; external APIs stay off until the owner explicitly enables them.

## Goals

- Make the library searchable by visual concepts such as `dog`, `car`,
  `landscape`, `network rack`, `flower`, and similar text prompts.
- Store provider outputs with model versions so analyses can be re-run safely.
- Keep every local and external analysis provider independently controlled.
- Use display or stream derivatives by default, not originals.
- Keep face recognition out of this first implementation phase.

## Systems

### OpenCLIP

- Purpose: local semantic image/text search.
- Runtime: Docker sidecar on the private Compose network.
- API keys: none.
- Rails flag: `analysis_openclip_enabled`.
- Output: image embeddings stored in a local vector index, with metadata in
  `photo_embeddings`.
- Search exposure: owner text search calls the local `/openclip/search`
  endpoint when OpenCLIP is enabled, filters matches through normal visibility
  rules, and merges those matches into stream-ordered results.
- Detail exposure: owner photo details show OpenCLIP embedding status,
  model/version, source derivative, and latest analysis errors.

### YOLO

- Purpose: local object detection with concrete labels and bounding boxes.
- Runtime: Docker sidecar on the private Compose network.
- API keys: none.
- Rails flag: `analysis_yolo_enabled`.
- Output: `photo_analysis_objects` rows plus normalized searchable tags.
- First implementation target: detect common objects and expose them in the
  owner metadata panel.

### OpenRouter Qwen Vision

- Purpose: create an accurate, editable 1-2 sentence caption plus visual search
  tags and clearly readable text.
- Runtime: a dedicated Solid Queue `vision` worker calls OpenRouter directly;
  no additional inference container is required.
- Default model: `qwen/qwen3-vl-30b-a3b-instruct`.
- API key: create a dedicated limited key at
  <https://openrouter.ai/settings/keys> and store it as
  `OPENROUTER_API_KEY` only on the server.
- Rails flags:
  - `analysis_openrouter_enabled` permits OpenRouter requests.
  - `analysis_openrouter_auto_new_enabled` captions new uploads and directory
    imports after their display derivative is ready.
- Privacy: every request requires a zero-data-retention provider, denies data
  collection, and requires support for the requested JSON response parameters.
  Disable prompt logging and the data-sharing discount in OpenRouter account
  privacy settings before enabling the feature.
- Source: a stripped, resized display JPEG. Originals and restricted photos are
  never sent. The initial implementation handles still images only.
- Context: when already available locally, the request includes the friendly
  cached place name, capture date, and camera make/model. It never sends exact
  coordinates, filenames, or plus-code-only locations, and it performs no
  additional geocoding calls.
- Caption behavior: Qwen fills the normal editable photo caption only when it is
  blank. A handwritten/imported caption is never overwritten. The generated
  source remains in `photo_analysis_runs.summary` after edits.
- Search: owner search includes completed Qwen summaries and normalized visual
  tags in addition to the visible caption.
- Accounting: request ID, tokens, provider response, and reported cost are saved
  per run. `OPENROUTER_BUDGET_USD` stops new calls once completed spend reaches
  the app ceiling. A hard limit on the OpenRouter key remains the final guard.

The production environment values are:

```sh
OPENROUTER_API_KEY=sk-or-v1-your-dedicated-key
OPENROUTER_VISION_MODEL=qwen/qwen3-vl-30b-a3b-instruct
OPENROUTER_BUDGET_USD=100
OPENROUTER_ESTIMATED_COST_USD=0.0025
```

After deployment, enable the two OpenRouter flags in **Repository Status >
Photo Analysis**. New ingests are automatic. Start the existing-library backfill
with a dry run and a 100-photo pilot:

```sh
docker compose exec -e DRY_RUN=true -e LIMIT=100 worker \
  bin/rails photos:openrouter_backfill
docker compose exec -e LIMIT=100 worker bin/rails photos:openrouter_backfill
```

Inspect captions, tags, failures, average cost, and projected spend in Repository
Status before increasing the batch. Continue in bounded chunks:

```sh
docker compose exec -e LIMIT=1000 worker bin/rails photos:openrouter_backfill
```

The task reserves each selected photo before queueing it, so rerunning it does
not duplicate paid requests. `LIMIT` defaults to 100 and is capped at 50,000.
The UI offers 25, 100, and 1,000-photo batches. Neither path is part of the
recurring local-analysis backfill.

### OpenAI Vision

- Purpose: rich descriptions and nuanced tags for concepts local models miss.
- Runtime: Rails worker calling the OpenAI API.
- API key: `OPENAI_API_KEY`, stored only server-side.
- Rails flags:
  - `analysis_openai_enabled`
  - `analysis_openai_public_only`
  - `analysis_openai_require_owner_confirm`
- Default posture: disabled, public-only, owner-confirmed.
- Security posture: send stripped display derivatives only; log every external
  send; never process private/restricted photos unless a separate future setting
  is added and explicitly enabled.

OpenAI states that API inputs and outputs are not used for training by default
unless the account opts in. Abuse-monitoring retention and stricter retention
options should be reviewed before enabling broad backfills.

## Data Model

- `photo_analysis_runs`: provider/model/status/raw output summary.
- `photo_analysis_tags`: normalized provider tags.
- `photo_analysis_objects`: detected objects and bounding boxes.
- `photo_embeddings`: metadata for vectors stored in the local index.

## Development Action Items

1. Run migrations and model tests for the analysis schema.
2. Build the local analysis sidecar with FastAPI.
3. Add `/health`, `/openclip/embed`, `/openclip/search`, and `/yolo/detect`
   endpoints to the sidecar.
4. Add Rails client classes for the sidecar.
5. Add `PhotoAnalysisBackfillJob` to enqueue provider-specific jobs.
6. Add `PhotoAnalysisOpenclipJob` and persist vector index metadata.
7. Add semantic search integration. Done for owner search; results are merged
   into stream order rather than ranked by similarity.
8. Add `PhotoAnalysisYoloJob` and normalize detections into tags.
9. Add owner UI for analysis status, tags, and detections.
10. Add OpenRouter Qwen captions with ZDR routing, spend accounting, and an
    owner-controlled pilot. Done.
11. Add OpenAI only if a later use case justifies another external provider.

## Production Action Items

1. Deploy migrations.
2. Add `ANALYSIS_LOCAL_CONTAINER_URL=http://analysis-local:8000`.
3. Add an `analysis-local` Docker service with read-only storage access and a
   persistent model/index cache volume.
4. Start with `analysis_openclip_enabled=false`, `analysis_yolo_enabled=false`,
   and `analysis_openai_enabled=false`.
5. Enable OpenCLIP first and run a small backfill batch.
6. Verify disk usage, runtime, CPU/GPU pressure, and search quality.
7. Enable YOLO for a small batch after OpenCLIP is stable.
8. Configure a dedicated limited OpenRouter key and a $100 app ceiling.
9. Enable OpenRouter and automatic new-upload captions, then run a 100-photo
   pilot before larger backfill batches.
10. Keep `OPENAI_API_KEY` absent until the owner is ready for an explicit pilot.
11. If OpenAI is piloted, create a dedicated OpenAI project/key with usage caps,
   keep public-only enabled, and run a tiny confirmed batch first.

## Local Sidecar

The deploy script enables the Compose `analysis` profile automatically, starts
the sidecar, verifies its storage mount, and waits for `/health`. It reuses the
existing `photos-analysis-local:latest` image after the first build; use
`REBUILD_ANALYSIS=true ./scripts/deploy` after sidecar code or dependency
changes. For manual local checks, the service is still available behind the
`analysis` profile:

```sh
docker compose --profile analysis up -d analysis-local
```

The sidecar exposes a health check plus OpenCLIP embedding/search endpoints.
Embeddings are written under the `analysis_index` Docker volume. YOLO endpoints
intentionally return `501` until their model dependencies and inference code are
added.

OpenCLIP search keeps the vector matrix in the sidecar process memory. The
sidecar warms that index in the background on startup by default; set
`OPENCLIP_WARM_ON_START=false` to disable warmup. Rails also caches semantic
query results briefly so returning to the same search does not call the sidecar
again.
