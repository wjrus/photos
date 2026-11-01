#!/usr/bin/env python3
"""Verify copied Disk-service blobs against a private database inventory."""
from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import time


def atomic_json(path: Path, value: dict) -> None:
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
            temporary = Path(output.name)
            os.chmod(temporary, 0o600)
            json.dump(value, output, separators=(",", ":"))
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def fingerprint(info: os.stat_result) -> list[int]:
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]


def open_blob(root_fd: int, key: str) -> int:
    # Do not follow a symlink in any component, including the blob itself.
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    first = os.open(key[:2], flags, dir_fd=root_fd)
    try:
        second = os.open(key[2:4], flags, dir_fd=first)
        try:
            return os.open(key, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=second)
        finally:
            os.close(second)
    finally:
        os.close(first)


def verify(storage: Path, inventory: Path, cache_path: Path, identity: str) -> dict:
    if not re.fullmatch(r"[a-f0-9]{64}", identity):
        raise ValueError("Invalid migration identity")
    storage = storage.resolve(strict=True)
    context = {"version": 1, "storage": str(storage), "identity": identity}
    cached = {}
    if cache_path.exists():
        try:
            previous = json.loads(cache_path.read_text())
            if isinstance(previous, dict) and all(previous.get(key) == value for key, value in context.items()):
                cached = previous.get("files", {})
                if not isinstance(cached, dict):
                    cached = {}
        except (ValueError, OSError):
            # An unusable cache costs a rehash; it never bypasses verification.
            cached = {}
    updated = {}
    totals = {"checked": 0, "cached": 0, "hashed": 0, "missing": 0, "mismatched": 0, "unsafe": 0, "bytes_read": 0}
    last_progress = time.monotonic()
    root_fd = os.open(storage, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        with inventory.open() as rows:
            for number, line in enumerate(rows, 1):
                try:
                    row = json.loads(line)
                    key = row["key"]
                    size = row["byte_size"]
                    checksum = row["checksum"]
                    if not isinstance(key, str) or not re.fullmatch(r"[a-z0-9]{4,128}", key):
                        raise ValueError
                    if type(size) is not int or size < 0:
                        raise ValueError
                    expected = base64.b64decode(checksum, validate=True)
                    if len(expected) != 16 or key in updated:
                        raise ValueError
                except (ValueError, TypeError, KeyError, binascii.Error):
                    raise ValueError(f"Invalid blob inventory row {number}") from None
                totals["checked"] += 1
                fd = None
                try:
                    fd = open_blob(root_fd, key)
                    before = os.fstat(fd)
                    if not stat.S_ISREG(before.st_mode):
                        totals["unsafe"] += 1
                        continue
                    if before.st_size != size:
                        totals["mismatched"] += 1
                        continue
                    stamp = [checksum, *fingerprint(before)]
                    if cached.get(key) == stamp:
                        totals["cached"] += 1
                        updated[key] = stamp
                        continue
                    # Active Storage records an MD5 checksum. This is an integrity
                    # comparison with the trusted source DB, not authentication.
                    digest = hashlib.md5(usedforsecurity=False)
                    while block := os.read(fd, 4 * 1024 * 1024):
                        digest.update(block)
                        totals["bytes_read"] += len(block)
                        if time.monotonic() - last_progress >= 10:
                            print("Blob verification: " + json.dumps(totals), flush=True)
                            last_progress = time.monotonic()
                    after = os.fstat(fd)
                    if digest.digest() != expected or fingerprint(before) != fingerprint(after):
                        totals["mismatched"] += 1
                        continue
                    updated[key] = stamp
                    totals["hashed"] += 1
                    if hasattr(os, "posix_fadvise"):
                        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
                except FileNotFoundError:
                    totals["missing"] += 1
                except OSError:
                    totals["unsafe"] += 1
                finally:
                    if fd is not None:
                        os.close(fd)
                    if time.monotonic() - last_progress >= 10:
                        print("Blob verification: " + json.dumps(totals), flush=True)
                        last_progress = time.monotonic()
    finally:
        os.close(root_fd)
    atomic_json(cache_path, {**context, "files": updated})
    return totals


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("storage", type=Path)
    parser.add_argument("inventory", type=Path)
    parser.add_argument("cache", type=Path)
    parser.add_argument("identity")
    args = parser.parse_args()
    os.nice(10)
    try:
        totals = verify(args.storage, args.inventory, args.cache, args.identity)
    except (OSError, ValueError) as error:
        print(f"Blob verification could not complete ({type(error).__name__}). Check the private inventory and storage access.", flush=True)
        return 1
    print("Blob verification: " + json.dumps(totals), flush=True)
    if totals["missing"] or totals["mismatched"] or totals["unsafe"]:
        print("Copied files do not match the database inventory. Source shutdown/target restore must not proceed.", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
