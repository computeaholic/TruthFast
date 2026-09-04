#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEBUG_IMAGE="${NODE_CACHE_DEBUG_IMAGE:-registry.threadforge.local:30500/mirror/docker.io/library/busybox@sha256:bfdec45b06a48dbc7d261ace48cec2d74849ecfc5129662c979f656cb31df469}"
WORKDIR="$(mktemp -d)"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

ensure_cluster_readable || exit $?

echo "[verify] ── node image cache enforcement ──"

mapfile -t nodes < <(run_real_kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | awk 'NF')

if [ "${#nodes[@]}" -eq 0 ]; then
  echo "[FAIL] no Kubernetes nodes found"
  exit 2
fi

for node_name in "${nodes[@]}"; do
  echo "[verify] checking node: node/${node_name}"

  before_file="$WORKDIR/${node_name}.before"
  after_file="$WORKDIR/${node_name}.after"
  raw_output_file="$WORKDIR/${node_name}.images.raw"
  output_file="$WORKDIR/${node_name}.images.json"
  stderr_file="$WORKDIR/${node_name}.stderr"

  run_real_kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' | sort > "$before_file"

  if command -v docker >/dev/null 2>&1 && docker inspect "$node_name" >/dev/null 2>&1; then
    if ! docker exec "$node_name" crictl images -o json > "$raw_output_file" 2> "$stderr_file"; then
      echo "[FAIL] unable to inspect node image cache via docker exec: node/${node_name}"
      exit 2
    fi
  elif ! run_real_kubectl debug "node/${node_name}" --profile=general --image="$DEBUG_IMAGE" --quiet -- chroot /host crictl images -o json > "$raw_output_file" 2> "$stderr_file"; then
    run_real_kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' | sort > "$after_file"
    comm -13 "$before_file" "$after_file" | while IFS=/ read -r namespace pod_name; do
      [ -n "$namespace" ] || continue
      [ -n "$pod_name" ] || continue
      run_real_kubectl delete pod "$pod_name" -n "$namespace" --ignore-not-found >/dev/null
    done
    echo "[FAIL] unable to inspect node image cache: node/${node_name}"
    exit 2
  fi

  python3 - "$raw_output_file" "$output_file" "$node_name" <<'PY'
import json
import pathlib
import sys

raw_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
node_name = sys.argv[3]
raw = raw_path.read_text(encoding="utf-8")

start = raw.find("{")
end = raw.rfind("}")
if start == -1 or end == -1 or end < start:
    print(f"[FAIL] node image cache output missing JSON payload for node/{node_name}", file=sys.stderr)
    raise SystemExit(2)

payload = raw[start:end + 1]
try:
    doc = json.loads(payload)
except json.JSONDecodeError as exc:
    print(f"[FAIL] invalid node image cache JSON for node/{node_name}: {exc}", file=sys.stderr)
    raise SystemExit(2)

output_path.write_text(json.dumps(doc), encoding="utf-8")
PY

  run_real_kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' | sort > "$after_file"
  comm -13 "$before_file" "$after_file" | while IFS=/ read -r namespace pod_name; do
    [ -n "$namespace" ] || continue
    [ -n "$pod_name" ] || continue
    run_real_kubectl delete pod "$pod_name" -n "$namespace" --ignore-not-found >/dev/null
  done

  python3 - "$output_file" "$node_name" <<'PY'
import json
import sys

image_doc = json.load(open(sys.argv[1], encoding="utf-8"))
node_name = sys.argv[2]
images = image_doc.get("images") if isinstance(image_doc, dict) else None
if not isinstance(images, list):
    print(f"[FAIL] node image cache output missing images list for node/{node_name}", file=sys.stderr)
    raise SystemExit(2)

violations = []
for image in images:
    if not isinstance(image, dict):
        continue
    refs = []
    for field in ("repoTags", "repoDigests"):
        values = image.get(field)
        if isinstance(values, list):
            refs.extend(value for value in values if isinstance(value, str))
    for ref in refs:
      if ref.startswith("docker.io/library/import-"):
        continue
      # kind-managed CNI and local-path provisioner images are injected by the
      # kind cluster bootstrap and cannot be removed from the node cache;
      # this is a documented kind runtime exception, same as static control-plane.
      if ref.startswith("docker.io/kindest/"):
        continue
      if ref.startswith(("docker.io/", "ghcr.io/", "quay.io/")):
        violations.append(ref)
        continue

if violations:
    unique = sorted(set(violations))
    print(f"[FAIL] NODE_CACHE_EXTERNAL_IMAGES: node/{node_name}", file=sys.stderr)
    for ref in unique:
      print(ref, file=sys.stderr)
    raise SystemExit(2)
PY
done

echo "[PASS] node image cache contains only internal images"
