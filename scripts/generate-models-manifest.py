#!/usr/bin/env python3
"""Generate models.json — the remote model catalogue served to Corvin clients.

The compiled-in `WhisperModel.all` array stays the source of truth for *which*
models exist and how they are described; this script parses it and enriches each
entry with the exact byte size and sha256 pulled from the hosting repository's
LFS metadata, so integrity data never has to be maintained by hand.

    ./scripts/generate-models-manifest.py                 # writes build/models.json
    ./scripts/generate-models-manifest.py --out /tmp/m.json

Adding a model to the catalogue means adding it to ModelManager.swift and
re-running this — clients pick it up without an app release. The Swift array
doubles as the offline fallback, so it is allowed to lag behind the manifest.
"""

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SWIFT_SOURCE = REPO_ROOT / "Shared/Core/ModelManager.swift"
SCHEMA_VERSION = 1

# Minimum app version able to load anything in this manifest. Bump per-model
# below if a future ggml format needs a newer whisper.cpp than shipped clients.
DEFAULT_MIN_APP_VERSION = "1.3.0"
# Models another runtime loads. An older client would take a family-less entry
# for whisper and hand a GGUF to whisper.cpp, so these are hidden from it.
FAMILY_MIN_APP_VERSION = {"gigaam": "1.5.4"}

HF_API = "https://huggingface.co/api/models/{repo}/tree/{rev}?recursive=true"


def fetch_json(url: str):
    with urllib.request.urlopen(url, timeout=60) as r:
        return json.load(r)


def lfs_index(repo: str, rev: str) -> dict:
    """path -> (sha256, size) for every LFS-backed file in a Hugging Face repo
    at `rev` — the revision the download URL resolves, so the hash matches."""
    try:
        tree = fetch_json(HF_API.format(repo=repo, rev=rev))
    except urllib.error.HTTPError as e:
        sys.exit(f"cannot read {repo} tree: HTTP {e.code}")
    out = {}
    for entry in tree:
        lfs = entry.get("lfs")
        if lfs and lfs.get("oid"):
            out[entry["path"]] = (lfs["oid"], lfs.get("size"))
    return out


FIELD = r'{key}:\s*(?:"([^"]*)"|([A-Za-z0-9_.]+))'


def parse_swift_catalogue() -> list:
    src = SWIFT_SOURCE.read_text()

    m = re.search(r'whisperURL\s*=\s*"([^"]+)"', src)
    if not m:
        sys.exit("could not find whisperURL in ModelManager.swift")
    whisper_url = m.group(1)

    body = re.search(r"static let all: \[WhisperModel\] = \[(.*?)\n    \]", src, re.S)
    if not body:
        sys.exit("could not find WhisperModel.all — did the declaration change?")

    models = []
    for block in re.findall(r"WhisperModel\((.*?)\n        \)", body.group(1), re.S):
        def field(key, default=None):
            mm = re.search(FIELD.format(key=key), block)
            if not mm:
                return default
            return mm.group(1) if mm.group(1) is not None else mm.group(2)

        # downloadURL is `URL(string: "…")!`, so the generic FIELD pattern would
        # capture the bare `URL` identifier instead of the literal inside it.
        um = re.search(r'downloadURL:\s*URL\(string:\s*"([^"]+)"', block)
        if not um:
            sys.exit(f"entry without a parsable downloadURL:\n{block}")
        url = um.group(1).replace("\\(whisperURL)", whisper_url)

        chip = field("chipRequirement")
        family = (field("family") or ".whisper").split(".")[-1]
        lm = re.search(r'languages:\s*\[([^\]]*)\]', block)
        languages = re.findall(r'"([^"]+)"', lm.group(1)) if lm else None
        entry = {
            "id": field("id"),
            "name": field("name"),
            "size": field("size"),
            "ramRequired": field("ramRequired"),
            "quality": field("quality"),
            "speed": field("speed"),
            "downloadURL": url,
            "recommended": field("recommended") == "true",
            "chipRequirement": None if chip in (None, "nil") else chip.split(".")[-1],
            "tier": (field("tier") or ".free").split(".")[-1],
        }
        # Only non-whisper entries carry the keys, so whisper entries stay
        # byte-identical to what older clients already have.
        if family != "whisper":
            entry["family"] = family
        if languages:
            entry["languages"] = languages
        models.append(entry)
    if not models:
        sys.exit("parsed zero models — the regex no longer matches the source")
    return models


def repo_and_path(url: str):
    """https://huggingface.co/<owner>/<repo>/resolve/<rev>/<path> -> (owner/repo, rev, path)"""
    m = re.match(r"https://huggingface\.co/([^/]+/[^/]+)/resolve/([^/]+)/(.+)$", url)
    return m.groups() if m else (None, None, None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(REPO_ROOT / "build/models.json"))
    ap.add_argument("--diarization-revision", default=None,
                    help="Hugging Face commit for the newest diarization entry "
                         "(default: its pinned revision)")
    args = ap.parse_args()

    models = parse_swift_catalogue()
    print(f"parsed {len(models)} models from ModelManager.swift")

    caches, missing = {}, []
    for m in models:
        repo, rev, path = repo_and_path(m["downloadURL"])
        if repo is None:
            missing.append((m["id"], "not a Hugging Face resolve URL"))
            continue
        if (repo, rev) not in caches:
            print(f"  reading LFS metadata for {repo}@{rev[:7]}…")
            caches[(repo, rev)] = lfs_index(repo, rev)
        meta = caches[(repo, rev)].get(path)
        if meta is None:
            missing.append((m["id"], f"{path} not found in {repo}"))
            continue
        sha, size = meta
        m["sha256"] = sha
        m["sizeBytes"] = size
        m["minAppVersion"] = FAMILY_MIN_APP_VERSION.get(m.get("family"), DEFAULT_MIN_APP_VERSION)

    if missing:
        for mid, why in missing:
            print(f"  MISSING {mid}: {why}", file=sys.stderr)
        sys.exit("refusing to emit a manifest with unverifiable models")

    diarization = [
        diarization_entry(spec, args.diarization_revision if last and args.diarization_revision
                          else spec["revision"])
        for last, spec in ((i == len(DIARIZATION_ENTRIES) - 1, spec)
                           for i, spec in enumerate(DIARIZATION_ENTRIES))
    ]

    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "models": models,
        # Ignored by clients that predate it (JSONDecoder skips unknown keys),
        # so schemaVersion stays 1.
        "diarization": diarization,
    }

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    total = sum(m["sizeBytes"] for m in models)
    print(f"wrote {out} — {len(models)} models, {total/2**30:.1f} GiB catalogued, "
          "diarization " + ", ".join(f"{d['id']} ({d['sizeBytes']/2**20:.1f} MiB)" for d in diarization))


# --- Speaker diarization models (macOS, corvin-diarize) ----------------------
#
# A directory of CoreML bundles rather than one file, so an entry lists every
# file. URLs are pinned to the revision, never `main`: clients only move to new
# models when a manifest naming them is published.

# Every entry stays published: a client takes the last one whose helperAPI its
# bundled corvin-diarize reads, so 1.5.0–1.5.2 keep getting pyannote while newer
# builds move to Nemotron. Append new entries; never edit a published one.
#
# `strip` is a repo-path prefix dropped from local paths that have it —
# corvin-diarize reads one flat directory, the repo keeps presets in
# subdirectories next to shared root files.
DIARIZATION_ENTRIES = [
    {
        "id": "fluid-offline",
        "repo": "FluidInference/speaker-diarization-coreml",
        "revision": "1ed7a662fdc7109e36d822db793ee6eebdaf8594",
        "paths": ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc",
                  "PldaRho.mlmodelc", "plda-parameters.json"],
        "strip": "",
        "helperAPI": 1,
        "minAppVersion": "1.5.0",
    },
    {
        # NVIDIA Nemotron 3 Diarization, `offline` preset (30 s context).
        "id": "nemotron3-offline",
        "repo": "FluidInference/nemotron-3-diarization-coreml",
        "revision": "1b0b133f6f8820292010afd776d8f9fbc9fca17e",
        "paths": ["monolithic/v2/Nemotron3Diarizer_offline.mlmodelc", "learnable_sil_emb.bin"],
        "strip": "monolithic/v2/",
        "helperAPI": 2,
        "minAppVersion": "1.5.3",
    },
]


def diarization_entry(spec: dict, revision: str) -> dict:
    """Files of one entry with sha256 and size. LFS files carry their sha256
    in the tree listing; the rest (small) are downloaded and hashed."""
    import hashlib

    repo = spec["repo"]
    tree_url = "https://huggingface.co/api/models/{repo}/tree/{rev}/{path}?recursive=true"
    listed = []
    for path in spec["paths"]:
        parent = path.rsplit("/", 1)[0] if "/" in path else ""
        siblings = fetch_json(f"https://huggingface.co/api/models/{repo}/tree/{revision}"
                              + (f"/{parent}" if parent else ""))
        top = next((e for e in siblings if e["path"] == path), None)
        if top is None:
            sys.exit(f"diarization: {path} not found in {repo} at {revision}")
        if top["type"] == "file":
            listed.append(top)
        else:
            listed += [e for e in fetch_json(tree_url.format(repo=repo, rev=revision, path=path))
                       if e["type"] == "file"]

    print(f"  {spec['id']}: {len(listed)} files at {revision[:7]}…")
    files = []
    for e in listed:
        url = f"https://huggingface.co/{repo}/resolve/{revision}/{e['path']}"
        sha = (e.get("lfs") or {}).get("oid")
        if not sha:
            with urllib.request.urlopen(url, timeout=120) as r:
                body = r.read()
            if len(body) != e["size"]:
                sys.exit(f"diarization: {e['path']} size {len(body)} != listed {e['size']}")
            sha = hashlib.sha256(body).hexdigest()
        local = e["path"].removeprefix(spec["strip"]) if spec["strip"] else e["path"]
        files.append({"path": local, "url": url, "sha256": sha, "sizeBytes": e["size"]})

    return {
        "id": f"{spec['id']}-{revision[:7]}",
        "revision": revision,
        "minAppVersion": spec["minAppVersion"],
        "helperAPI": spec["helperAPI"],
        "sizeBytes": sum(f["sizeBytes"] for f in files),
        "files": files,
    }


if __name__ == "__main__":
    main()
