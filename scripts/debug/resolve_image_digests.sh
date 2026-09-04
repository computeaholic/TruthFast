#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_PATH="${1:-$REPO_ROOT/artifacts/debug/runtime_image_resolution.json}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[FAIL] kubectl not found in PATH" >&2
  exit 10
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[FAIL] python3 not found in PATH" >&2
  exit 10
fi

mkdir -p "$(dirname "$OUT_PATH")"

python3 - "$OUT_PATH" <<'PY'
import json
import pathlib
import re
import subprocess
import sys

out_path = pathlib.Path(sys.argv[1])

proc = subprocess.run(
    ["kubectl", "get", "pods", "-A", "--request-timeout=30s", "-o", "json"],
    text=True,
    capture_output=True,
    check=False,
)
if proc.returncode != 0:
    raise SystemExit(proc.stderr.strip() or proc.stdout.strip() or "kubectl get pods failed")

doc = json.loads(proc.stdout)
items = doc.get("items") if isinstance(doc, dict) else None
if not isinstance(items, list):
    raise SystemExit("kubectl output missing items list")

digest_re = re.compile(r"@(?P<digest>sha256:[0-9a-fA-F]{64})$")
spec_digest_re = re.compile(r"^(?P<name>.+?)(?::(?P<tag>[^/@]+))?@(?P<digest>sha256:[0-9a-fA-F]{64})$")


def normalize_image_id(image_id: str) -> str:
    ref = (image_id or "").strip()
    for prefix in ("docker-pullable://", "docker://", "containerd://"):
        if ref.startswith(prefix):
            ref = ref[len(prefix):]
            break
    return ref


def repo_without_tag(image: str) -> str:
    ref = (image or "").strip()
    if "@" in ref:
        ref = ref.split("@", 1)[0]
    last_segment = ref.rsplit("/", 1)[-1]
    if ":" in last_segment:
        ref = ref.rsplit(":", 1)[0]
    return ref


def resolved_digest(image_id: str) -> str:
    normalized = normalize_image_id(image_id)
    match = digest_re.search(normalized)
    return match.group("digest").lower() if match else ""


entries = []
for pod in items:
    if not isinstance(pod, dict):
        continue
    metadata = pod.get("metadata") if isinstance(pod.get("metadata"), dict) else {}
    spec = pod.get("spec") if isinstance(pod.get("spec"), dict) else {}
    status = pod.get("status") if isinstance(pod.get("status"), dict) else {}
    namespace = metadata.get("namespace", "")
    pod_name = metadata.get("name", "")

    spec_maps = {
        "container": {
            c.get("name"): c.get("image")
            for c in (spec.get("containers") or [])
            if isinstance(c, dict) and isinstance(c.get("name"), str) and isinstance(c.get("image"), str)
        },
        "init_container": {
            c.get("name"): c.get("image")
            for c in (spec.get("initContainers") or [])
            if isinstance(c, dict) and isinstance(c.get("name"), str) and isinstance(c.get("image"), str)
        },
    }
    status_maps = {
        "container": status.get("containerStatuses") or [],
        "init_container": status.get("initContainerStatuses") or [],
    }

    for container_type in ("container", "init_container"):
        for container_name, image in spec_maps[container_type].items():
            status_entry = next(
                (
                    entry
                    for entry in status_maps[container_type]
                    if isinstance(entry, dict) and entry.get("name") == container_name
                ),
                {},
            )
            image_id = status_entry.get("imageID", "") if isinstance(status_entry, dict) else ""
            normalized_image_id = normalize_image_id(image_id)
            digest = resolved_digest(image_id)
            resolved_ref = f"{repo_without_tag(image)}@{digest}" if digest else ""
            spec_match = spec_digest_re.match((image or "").strip())
            entries.append(
                {
                    "namespace": namespace,
                    "pod": pod_name,
                    "container_name": container_name,
                    "container_type": container_type,
                    "image": image,
                    "image_id": image_id,
                    "image_id_ref": normalized_image_id,
                    "resolved_digest": digest,
                    "resolved_ref": resolved_ref,
                    "spec_canonical_ref": f"{repo_without_tag(image)}@{spec_match.group('digest').lower()}" if spec_match else "",
                    "spec_digest": spec_match.group("digest").lower() if spec_match else "",
                }
            )

payload = {
    "total_runtime_images": len(entries),
    "entries": entries,
}
out_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
print(f"[PASS] wrote {out_path}")
PY
