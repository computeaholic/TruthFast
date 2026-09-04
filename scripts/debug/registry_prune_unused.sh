#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_PATH="${ARTIFACT_PATH:-$REPO_ROOT/artifacts/registry_audit.json}"
REGISTRY_HOSTPORT="${THREADFORGE_REGISTRY:-registry.threadforge.local:30500}"
REGISTRY_URL="${REGISTRY_URL:-https://${REGISTRY_HOSTPORT}}"
APPLY=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply)
      APPLY=true
      shift
      ;;
    *)
      echo "[FAIL] unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

bash "$REPO_ROOT/scripts/verify/registry_audit.sh" >/dev/null

python3 - "$ARTIFACT_PATH" "$REGISTRY_URL" "$APPLY" <<'PY'
from __future__ import annotations

import json
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

artifact_path = Path(sys.argv[1])
registry_url = sys.argv[2].rstrip("/")
apply = sys.argv[3].lower() == "true"

artifact = json.loads(artifact_path.read_text())
runtime = set(artifact.get("runtime_images") or [])
manifests = set(artifact.get("manifest_images") or [])
inventory = artifact.get("registry_inventory") or []

groups: dict[tuple[str, str], list[dict[str, str]]] = defaultdict(list)
for entry in inventory:
    if not isinstance(entry, dict):
        continue
    repo = entry.get("repo") or ""
    digest = entry.get("digest") or ""
    canonical_ref = entry.get("canonical_ref") or ""
    if not repo or not digest or not canonical_ref:
        continue
    groups[(repo, digest)].append(entry)

candidates: list[dict[str, object]] = []
for (repo, digest), entries in sorted(groups.items()):
    canonical_ref = entries[0]["canonical_ref"]
    if canonical_ref in runtime or canonical_ref in manifests:
        continue
    candidates.append(
        {
            "repo": repo,
            "digest": digest,
            "canonical_ref": canonical_ref,
            "tags": sorted(entry.get("tag") or "" for entry in entries if entry.get("tag")),
        }
    )

print(f"REGISTRY_PRUNE_CANDIDATE_COUNT={len(candidates)}")
if not candidates:
    print("[PASS] registry prune: no unused registry digests found")
    raise SystemExit(0)

if not apply:
    print("[registry-prune] dry-run mode; pass --apply to delete unused digests")
    for candidate in candidates:
        tags = ",".join(candidate["tags"])
        print(f"DRY_RUN {candidate['repo']} {candidate['digest']} tags={tags}")
    raise SystemExit(0)

for candidate in candidates:
    repo = candidate["repo"]
    digest = candidate["digest"]
    url = f"{registry_url}/v2/{repo}/manifests/{digest}"
    proc = subprocess.run(
        ["curl", "-ksS", "-X", "DELETE", "-o", "/dev/null", "-w", "%{http_code}", url],
        text=True,
        capture_output=True,
        check=False,
    )
    status = (proc.stdout or "").strip()
    if status != "202":
        raise SystemExit(f"[FAIL] registry prune delete failed for {repo}@{digest} (HTTP {status or '000'})")
    print(f"DELETED {repo}@{digest}")

print(f"[PASS] registry prune: deleted {len(candidates)} unused registry digest(s)")
PY
