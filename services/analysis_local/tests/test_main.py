import os
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

import numpy as np
from fastapi.testclient import TestClient

from app import main


class OpenclipIndexTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.runtime = main.OpenclipRuntime.__new__(main.OpenclipRuntime)
        self.runtime.np = np
        self.runtime.index_dir = Path(self.directory.name)
        self.runtime.index_lock = threading.RLock()
        self.runtime.index_photo_ids = []
        self.runtime.index_matrix = None
        self.runtime.index_loaded = False
        self.runtime.model_name = "synthetic"
        self.runtime.pretrained = "fixture"

    def test_first_embedding_preserves_persisted_photos_without_warmup(self):
        np.save(self.runtime.index_dir / "101.npy", np.array([1.0, 0.0], dtype="float32"))

        self.runtime.save_embedding(202, [0.0, 1.0])

        photo_ids, matrix = self.runtime.memory_index()
        self.assertEqual([101, 202], photo_ids)
        np.testing.assert_array_equal(matrix, [[1.0, 0.0], [0.0, 1.0]])
        with patch.object(self.runtime, "embed_text", return_value=np.array([1.0, 0.0])):
            self.assertEqual(101, self.runtime.search("synthetic query", 1)[0]["photo_id"])

    def test_concurrent_warmup_and_writes_preserve_all_photos(self):
        np.save(self.runtime.index_dir / "101.npy", np.array([1.0, 0.0], dtype="float32"))
        start = threading.Barrier(3)

        def write(photo_id):
            start.wait(timeout=5)
            self.runtime.save_embedding(photo_id, [0.0, 1.0])

        def warmup():
            start.wait(timeout=5)
            self.runtime.memory_index()

        with ThreadPoolExecutor(max_workers=3) as executor:
            futures = [executor.submit(write, 202), executor.submit(write, 303), executor.submit(warmup)]
            for future in futures:
                future.result(timeout=5)

        photo_ids, matrix = self.runtime.memory_index()
        self.assertEqual([101, 202, 303], sorted(photo_ids))
        self.assertEqual((3, 2), matrix.shape)

    def test_replacing_an_embedding_preserves_existing_search_snapshots(self):
        self.runtime.save_embedding(101, [1.0, 0.0])
        old_ids, old_matrix = self.runtime.memory_index()

        self.runtime.save_embedding(101, [0.0, 1.0])

        self.assertEqual([101], old_ids)
        np.testing.assert_array_equal(old_matrix, [[1.0, 0.0]])
        self.assertEqual([101], self.runtime.memory_index()[0])
        np.testing.assert_array_equal(self.runtime.memory_index()[1], [[0.0, 1.0]])

    def test_failed_write_preserves_previous_embedding(self):
        self.runtime.save_embedding(101, [1.0, 0.0])
        with patch.object(np, "save", side_effect=OSError("synthetic disk failure")):
            with self.assertRaises(OSError):
                self.runtime.save_embedding(101, [0.0, 1.0])

        np.testing.assert_array_equal(np.load(self.runtime.index_dir / "101.npy"), [1.0, 0.0])
        self.assertEqual([], list(self.runtime.index_dir.glob("*.tmp")))

    def test_concurrent_first_requests_share_one_runtime(self):
        start = threading.Barrier(4)

        def get_runtime():
            start.wait(timeout=5)
            return main.openclip_runtime()

        with patch.object(main, "_runtime", None), patch.object(main, "OpenclipRuntime", return_value=self.runtime) as factory:
            with ThreadPoolExecutor(max_workers=4) as executor:
                results = list(executor.map(lambda _: get_runtime(), range(4)))

            factory.assert_called_once()
            self.assertTrue(all(runtime is self.runtime for runtime in results))


class AnalysisApiTest(unittest.TestCase):
    def test_health_and_request_validation_do_not_load_models(self):
        with patch.dict(os.environ, {"OPENCLIP_WARM_ON_START": "false"}), patch.object(main, "OpenclipRuntime") as factory:
            with TestClient(main.app) as client:
                self.assertEqual({"status": "ok"}, client.get("/health").json())
                self.assertEqual(422, client.post("/openclip/search", json={"query": "", "limit": 201}).status_code)
                self.assertEqual(422, client.post("/openclip/embed", json={"photo_id": 1, "image_path": ""}).status_code)
                self.assertEqual(501, client.post("/yolo/detect", json={"photo_id": 1, "image_path": "/synthetic.jpg"}).status_code)
            factory.assert_not_called()


if __name__ == "__main__":
    unittest.main()
