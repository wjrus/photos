import os
import logging
import threading
from functools import lru_cache
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field


app = FastAPI(title="Photos Local Analysis", version="0.1.0")
logger = logging.getLogger("photos.analysis_local")


@app.exception_handler(Exception)
async def unhandled_exception_handler(_request: Request, exc: Exception) -> JSONResponse:
    logger.exception("Unhandled local analysis error")
    return JSONResponse(
        status_code=500,
        content={"detail": f"{exc.__class__.__name__}: {exc}"},
    )


class ImagePathRequest(BaseModel):
    photo_id: int
    image_path: str = Field(min_length=1)
    source_variant: str = "display"


class TextSearchRequest(BaseModel):
    query: str = Field(min_length=1)
    limit: int = Field(default=25, ge=1, le=200)


class OpenclipRuntime:
    def __init__(self) -> None:
        import numpy as np
        import open_clip
        import torch
        from PIL import Image

        self.np = np
        self.open_clip = open_clip
        self.torch = torch
        self.image_class = Image
        self.model_name = os.getenv("OPENCLIP_MODEL", "ViT-B-32")
        self.pretrained = os.getenv("OPENCLIP_PRETRAINED", "laion2b_s34b_b79k")
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.model, _, self.preprocess = open_clip.create_model_and_transforms(
            self.model_name,
            pretrained=self.pretrained,
            device=self.device,
        )
        self.model.eval()
        self.tokenizer = open_clip.get_tokenizer(self.model_name)
        self.index_dir = Path(os.getenv("ANALYSIS_INDEX_DIR", "/analysis")) / "openclip" / self.model_key
        self.index_dir.mkdir(parents=True, exist_ok=True)
        self.index_lock = threading.Lock()
        self.index_photo_ids: list[int] = []
        self.index_matrix: Any | None = None
        self.index_loaded = False

    @property
    def model_key(self) -> str:
        return f"{self.model_name}-{self.pretrained}".replace("/", "_")

    def embed_image(self, image_path: str) -> list[float]:
        path = Path(image_path)
        if not path.is_file():
            raise HTTPException(status_code=404, detail=f"Image path does not exist: {image_path}")

        image = self.preprocess(self.image_class.open(path).convert("RGB")).unsqueeze(0).to(self.device)
        with self.torch.no_grad():
            features = self.model.encode_image(image)
            features = features / features.norm(dim=-1, keepdim=True)
        return features.squeeze(0).cpu().numpy().astype("float32").tolist()

    def embed_text(self, text: str) -> Any:
        tokens = self.tokenizer([text]).to(self.device)
        with self.torch.no_grad():
            features = self.model.encode_text(tokens)
            features = features / features.norm(dim=-1, keepdim=True)
        return features.squeeze(0).cpu().numpy().astype("float32")

    def save_embedding(self, photo_id: int, embedding: list[float]) -> str:
        index_key = f"{self.model_key}/{photo_id}.npy"
        path = self.index_dir / f"{photo_id}.npy"
        self.np.save(path, self.np.array(embedding, dtype="float32"))
        self.update_memory_index(photo_id, embedding)
        return index_key

    def search(self, query: str, limit: int) -> list[dict[str, Any]]:
        text_embedding = self.embed_text(query)
        photo_ids, matrix = self.memory_index()
        if matrix is None or not photo_ids:
            return []

        scores = matrix @ text_embedding
        top_count = min(limit, len(photo_ids))
        if top_count <= 0:
            return []

        top_indexes = self.np.argpartition(scores, -top_count)[-top_count:]
        top_indexes = top_indexes[self.np.argsort(scores[top_indexes])[::-1]]
        return [
            {"photo_id": photo_ids[index], "score": float(scores[index])}
            for index in top_indexes
        ]

    def memory_index(self) -> tuple[list[int], Any | None]:
        with self.index_lock:
            if not self.index_loaded:
                self.load_memory_index()

            return list(self.index_photo_ids), self.index_matrix

    def load_memory_index(self) -> None:
        photo_ids = []
        embeddings = []
        for path in sorted(self.index_dir.glob("*.npy")):
            try:
                embedding = self.np.load(path).astype("float32")
            except Exception:
                logger.exception("Could not load OpenCLIP embedding %s", path)
                continue

            photo_ids.append(int(path.stem))
            embeddings.append(embedding)

        self.index_photo_ids = photo_ids
        self.index_matrix = self.np.vstack(embeddings) if embeddings else None
        self.index_loaded = True
        logger.info("Loaded %d OpenCLIP embeddings into memory", len(photo_ids))

    def update_memory_index(self, photo_id: int, embedding: list[float]) -> None:
        with self.index_lock:
            if self.index_matrix is None:
                self.index_photo_ids = [photo_id]
                self.index_matrix = self.np.array([embedding], dtype="float32")
            elif photo_id in self.index_photo_ids:
                index = self.index_photo_ids.index(photo_id)
                self.index_matrix[index] = self.np.array(embedding, dtype="float32")
            else:
                self.index_photo_ids.append(photo_id)
                self.index_matrix = self.np.vstack([
                    self.index_matrix,
                    self.np.array([embedding], dtype="float32"),
                ])

            self.index_loaded = True


@lru_cache(maxsize=1)
def openclip_runtime() -> OpenclipRuntime:
    return OpenclipRuntime()


def warm_openclip_runtime() -> None:
    try:
        runtime = openclip_runtime()
        runtime.memory_index()
    except Exception:
        logger.exception("Could not warm OpenCLIP runtime")


@app.on_event("startup")
def start_openclip_warmup() -> None:
    if os.getenv("OPENCLIP_WARM_ON_START", "true").lower() in {"1", "true", "yes"}:
        threading.Thread(target=warm_openclip_runtime, daemon=True).start()


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/openclip/embed")
def openclip_embed(_request: ImagePathRequest) -> dict[str, Any]:
    runtime = openclip_runtime()
    embedding = runtime.embed_image(_request.image_path)
    index_key = runtime.save_embedding(_request.photo_id, embedding)
    return {
        "provider": "openclip",
        "model": runtime.model_name,
        "model_version": runtime.pretrained,
        "dimensions": len(embedding),
        "index_key": index_key,
    }


@app.post("/openclip/search")
def openclip_search(_request: TextSearchRequest) -> dict[str, Any]:
    runtime = openclip_runtime()
    return {
        "provider": "openclip",
        "model": runtime.model_name,
        "model_version": runtime.pretrained,
        "results": runtime.search(_request.query, _request.limit),
    }


@app.post("/yolo/detect")
def yolo_detect(_request: ImagePathRequest) -> dict[str, Any]:
    raise HTTPException(status_code=501, detail="YOLO detection is not implemented yet.")
