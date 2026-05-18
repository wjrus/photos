# Photo Analysis Plan

Photo analysis is intentionally provider-based and opt-in. Local processors run
first; external APIs stay off until the owner explicitly enables them.

## Goals

- Make the library searchable by visual concepts such as `dog`, `car`,
  `landscape`, `network rack`, `flower`, and similar text prompts.
- Store provider outputs with model versions so analyses can be re-run safely.
- Keep local analysis and OpenAI analysis independently controlled.
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
- First implementation target: generate embeddings for display derivatives and
  search by text query.

### YOLO

- Purpose: local object detection with concrete labels and bounding boxes.
- Runtime: Docker sidecar on the private Compose network.
- API keys: none.
- Rails flag: `analysis_yolo_enabled`.
- Output: `photo_analysis_objects` rows plus normalized searchable tags.
- First implementation target: detect common objects and expose them in the
  owner metadata panel.

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
7. Add semantic search integration.
8. Add `PhotoAnalysisYoloJob` and normalize detections into tags.
9. Add owner UI for analysis status, tags, and detections.
10. Add OpenAI only after local systems are useful and privacy settings are
    reviewed.

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
8. Keep `OPENAI_API_KEY` absent until the owner is ready for an explicit pilot.
9. If OpenAI is piloted, create a dedicated OpenAI project/key with usage caps,
   keep public-only enabled, and run a tiny confirmed batch first.

## Local Sidecar

The deploy script enables the Compose `analysis` profile automatically, builds
the `analysis-local` image, starts the sidecar, verifies its storage mount, and
waits for `/health`. For manual local checks, the service is still available
behind the `analysis` profile:

```sh
docker compose --profile analysis up -d analysis-local
```

The sidecar exposes a health check plus OpenCLIP embedding/search endpoints.
Embeddings are written under the `analysis_index` Docker volume. YOLO endpoints
intentionally return `501` until their model dependencies and inference code are
added.
