import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    "migration_files", Path(__file__).resolve().parents[2] / "scripts/lib/migration_files.py"
)
migration_files = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(migration_files)


class MigrationFilesTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.storage = self.root / "storage"
        self.storage.mkdir()
        self.inventory = self.root / "inventory.jsonl"
        self.cache = self.root / "cache.json"
        self.identity = "a" * 64
        self.key = "abcdefgh1234"
        self.content = b"synthetic photo bytes"
        self.path = self.storage / self.key[:2] / self.key[2:4] / self.key
        self.path.parent.mkdir(parents=True)
        self.path.write_bytes(self.content)
        self.write_inventory()

    def tearDown(self):
        self.temporary.cleanup()

    def write_inventory(self, **changes):
        row = {
            "key": self.key,
            "byte_size": len(self.content),
            "checksum": base64.b64encode(hashlib.md5(self.content).digest()).decode(),
            **changes,
        }
        self.inventory.write_text(json.dumps(row) + "\n")

    def verify(self):
        return migration_files.verify(self.storage, self.inventory, self.cache, self.identity)

    def test_matching_files_are_hashed_then_reused_without_reading_file_contents(self):
        self.assertEqual(self.verify()["hashed"], 1)
        self.assertEqual(self.cache.stat().st_mode & 0o777, 0o600)
        with mock.patch.object(migration_files.os, "read", side_effect=AssertionError("unexpected rehash")):
            result = self.verify()
        self.assertEqual(result["cached"], 1)
        self.assertEqual(result["hashed"], 0)

    def test_same_size_same_mtime_changes_are_not_hidden_by_the_cache(self):
        self.verify()
        before = self.path.stat()
        replacement = self.path.with_name("replacement")
        replacement.write_bytes(b"x" * len(self.content))
        os.utime(replacement, ns=(before.st_atime_ns, before.st_mtime_ns))
        os.replace(replacement, self.path)
        result = self.verify()
        self.assertEqual(result["mismatched"], 1)
        self.assertEqual(result["cached"], 0)

    def test_missing_and_truncated_files_are_rejected(self):
        self.path.unlink()
        self.assertEqual(self.verify()["missing"], 1)
        self.path.write_bytes(b"short")
        self.assertEqual(self.verify()["mismatched"], 1)

    def test_corrupt_cache_is_discarded_and_file_is_rehashed(self):
        for invalid in ("incomplete JSON", "[]", "null"):
            with self.subTest(invalid=invalid):
                self.cache.write_text(invalid)
                self.assertEqual(self.verify()["hashed"], 1)

    def test_cache_for_another_migration_cannot_skip_hashing(self):
        self.verify()
        self.identity = "b" * 64
        self.assertEqual(self.verify()["hashed"], 1)

    def test_blob_and_parent_symlinks_are_rejected(self):
        self.path.unlink()
        outside = self.root / "outside"
        outside.write_bytes(self.content)
        self.path.symlink_to(outside)
        self.assertEqual(self.verify()["unsafe"], 1)
        self.path.unlink()
        self.path.parent.rmdir()
        outside_dir = self.root / "outside-directory"
        outside_dir.mkdir()
        (outside_dir / self.key).write_bytes(self.content)
        self.path.parent.symlink_to(outside_dir, target_is_directory=True)
        self.assertEqual(self.verify()["unsafe"], 1)

    def test_invalid_keys_and_checksums_fail_closed(self):
        for changes in ({"key": "../escape"}, {"checksum": "not-base64"}, {"byte_size": -1}):
            with self.subTest(changes=changes):
                self.write_inventory(**changes)
                with self.assertRaises(ValueError):
                    self.verify()

    def test_fifo_is_rejected_without_waiting_for_a_writer(self):
        self.path.unlink()
        os.mkfifo(self.path)
        self.assertEqual(self.verify()["unsafe"], 1)


if __name__ == "__main__":
    unittest.main()
