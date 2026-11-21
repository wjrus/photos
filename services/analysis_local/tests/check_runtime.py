# Run inside the full analysis environment from its project directory:
# python - < tests/check_runtime.py
# Synthetic inputs only. No pretrained weights are downloaded.
import os
from importlib.metadata import distributions
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import numpy as np
import open_clip
import torch
from PIL import Image
from torchvision.ops import nms

from app.main import OpenclipRuntime, health


assert torch.version.cuda is None
assert not torch.cuda.is_available()
gpu_packages = [
    package.metadata["Name"] for package in distributions()
    if package.metadata["Name"].lower().startswith(("nvidia-", "cuda-"))
    or package.metadata["Name"].lower() == "triton"
]
assert not gpu_packages, gpu_packages
assert health()["status"] == "ok"
assert nms(torch.tensor([[0., 0., 1., 1.]]), torch.tensor([1.]), 0.5).tolist() == [0]

torch.set_num_threads(2)
model, _, preprocess = open_clip.create_model_and_transforms("ViT-B-32", pretrained=None, device="cpu")
model.eval()
tokens = open_clip.get_tokenizer("ViT-B-32")(["synthetic test photo"])
with torch.inference_mode():
    image_features = model.encode_image(preprocess(Image.new("RGB", (32, 32))).unsqueeze(0))
    text_features = model.encode_text(tokens)
for features in (image_features, text_features):
    assert features.shape == (1, 512)
    assert features.device.type == "cpu"
    assert torch.isfinite(features).all()

with TemporaryDirectory() as directory, patch.dict(os.environ, {
    "ANALYSIS_INDEX_DIR": directory,
    "OPENCLIP_MODEL": "ViT-B-32",
    "OPENCLIP_PRETRAINED": "laion2b_s34b_b79k",
}), patch.object(open_clip, "create_model_and_transforms", return_value=(model, None, preprocess)) as factory:
    # Exercise Photos' factory call and real image/text/index path using the
    # synthetic model above instead of downloading the pretrained checkpoint.
    runtime = OpenclipRuntime()
    factory.assert_called_once_with("ViT-B-32", pretrained="laion2b_s34b_b79k", device="cpu")
    image_path = Path(directory) / "synthetic.png"
    Image.new("RGB", (39, 61), color=(30, 90, 160)).save(image_path)
    embedding = runtime.embed_image(str(image_path))
    assert len(embedding) == 512
    assert np.isfinite(embedding).all()
    np.testing.assert_allclose(np.linalg.norm(embedding), 1.0, rtol=1e-5)
    np.testing.assert_allclose(np.linalg.norm(runtime.embed_text("synthetic test photo")), 1.0, rtol=1e-5)
    assert runtime.save_embedding(101, embedding) == "ViT-B-32-laion2b_s34b_b79k/101.npy"
    assert runtime.search("synthetic test photo", 1)[0]["photo_id"] == 101

    restored = OpenclipRuntime()
    photo_ids, matrix = restored.memory_index()
    assert photo_ids == [101]
    np.testing.assert_array_equal(matrix[0], np.array(embedding, dtype="float32"))

print("CPU inference, normalized 512-dimensional embeddings, search, and persisted index reload passed")
