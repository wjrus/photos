from typing import Any

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field


app = FastAPI(title="Photos Local Analysis", version="0.1.0")


class ImagePathRequest(BaseModel):
    photo_id: int
    image_path: str = Field(min_length=1)
    source_variant: str = "display"


class TextSearchRequest(BaseModel):
    query: str = Field(min_length=1)
    limit: int = Field(default=25, ge=1, le=200)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/openclip/embed")
def openclip_embed(_request: ImagePathRequest) -> dict[str, Any]:
    raise HTTPException(status_code=501, detail="OpenCLIP embedding is not implemented yet.")


@app.post("/openclip/search")
def openclip_search(_request: TextSearchRequest) -> dict[str, Any]:
    raise HTTPException(status_code=501, detail="OpenCLIP search is not implemented yet.")


@app.post("/yolo/detect")
def yolo_detect(_request: ImagePathRequest) -> dict[str, Any]:
    raise HTTPException(status_code=501, detail="YOLO detection is not implemented yet.")
