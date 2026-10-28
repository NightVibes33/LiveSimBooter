#!/usr/bin/env python3
"""Package only LiveSimBooter-written guest helper binaries for USB download.

No Apple .simruntime, Xcode SDK files, shared caches, dyld_sim or launchd_sim.
Each gzip stream is split into <=4MiB independently SHA-256 checked pieces.
"""
import argparse
import gzip
import hashlib
import json
import pathlib
import shutil
import sys
from datetime import datetime, timezone

CHUNK_SIZE = 4 * 1024 * 1024
ALLOWLIST = (
    "usr/lib/libLiveSimSpawn.dylib",
    "bin/spawn-probe",
    "usr/libexec/terminal-fish",
    "usr/libexec/display-settings",
    "usr/libexec/launchctl-control",
    "usr/libexec/app-registration",
)


def digest(file: pathlib.Path) -> str:
    hash_value = hashlib.sha256()
    with file.open("rb") as source:
        while data := source.read(CHUNK_SIZE):
            hash_value.update(data)
    return hash_value.hexdigest()


def publish(source: pathlib.Path, output: pathlib.Path) -> None:
    if output.exists():
        shutil.rmtree(output)
    (output / "cache").mkdir(parents=True)
    entries = []
    for relative in ALLOWLIST:
        original = source / relative
        if not original.is_file() or original.is_symlink() or not original.stat().st_size:
            raise RuntimeError(f"Missing or empty, non-regular helper: {relative}")
        hash_value = digest(original)
        compressed = output / "temp.gz"
        with compressed.open("wb") as target:
            with gzip.GzipFile(filename="", fileobj=target, mode="wb", compresslevel=9, mtime=0) as encoder:
                with original.open("rb") as input_file:
                    shutil.copyfileobj(input_file, encoder, 1024 * 1024)
        chunks = []
        with compressed.open("rb") as input_file:
            part_number = 0
            while data := input_file.read(CHUNK_SIZE):
                file_name = f"cache/{hash_value}-{part_number:04d}.part"
                (output / file_name).write_bytes(data)
                chunks.append({
                    "name": file_name,
                    "size": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                })
                part_number += 1
        compressed.unlink()
        entries.append({
            "path": relative,
            "sha256": hash_value,
            "size": original.stat().st_size,
            "compression": "gzip",
            "chunks": chunks,
        })
    document = {
        "formatVersion": 1,
        "guestBuild": "23A343",
        "contentType": "open-source-helpers",
        "bootable": False,
        "description": "LiveSimBooter authored guest helpers only; does NOT include Apple's iOS Simulator RuntimeRoot, dyld_sim, launchd_sim or dyld shared cache.",
        "files": entries,
    }
    (output / "manifest.json").write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    (output / "README.md").write_text(
        "# LiveSimBooter 23A343 open-source helper cache\n\n"
        "This generated branch contains original LiveSimBooter guest helper programs only.\n"
        "It **does not** include an Apple iOS Simulator runtime, code signatures "
        "suitable for running Apple's guest processes, or a bootable simulator.\n"
        "Downloads are verified individually against `manifest.json` and "
        "decompressed directly into a user-selected USB directory.\n"
        "Each part is at most 4 MiB to support normal Git-hosted files.\n"
    )
    validate(output)


def validate(output: pathlib.Path) -> None:
    obj = json.loads((output / "manifest.json").read_text())
    assert obj["contentType"] == "open-source-helpers" and obj["bootable"] is False
    assert [file["path"] for file in obj["files"]] == list(ALLOWLIST)
    for entry in obj["files"]:
        encoded = b""
        for chunk in entry["chunks"]:
            part = output / chunk["name"]
            assert part.is_file() and 0 < part.stat().st_size <= CHUNK_SIZE
            assert part.stat().st_size == chunk["size"]
            assert digest(part) == chunk["sha256"]
            encoded += part.read_bytes()
        decoded = gzip.decompress(encoded)
        assert len(decoded) == entry["size"]
        assert hashlib.sha256(decoded).hexdigest() == entry["sha256"]
    print(f"Validated {len(obj['files'])} files, {sum(len(f['chunks']) for f in obj['files'])} split chunks")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", type=pathlib.Path, required=True)
    ap.add_argument("--output", type=pathlib.Path, required=True)
    args = ap.parse_args()
    publish(args.input.resolve(), args.output.resolve())


if __name__ == "__main__":
    main()
