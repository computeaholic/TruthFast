#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_PATH="${1:-$REPO_ROOT/artifacts/runtime/runtime_images.txt}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[FAIL] kubectl not found in PATH" >&2
  exit 10
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "[FAIL] jq not found in PATH" >&2
  exit 10
fi

mkdir -p "$(dirname "$OUT_PATH")"

kubectl get pods -A -o json \
  | jq -r '
    .items[]
    | .metadata.namespace as $ns
    | .metadata.name as $pod
    | (.spec.containers[]?, .spec.initContainers[]?)
    | "\($ns) \($pod) \(.name) \(.image)"
  ' > "$OUT_PATH"

echo "[PASS] wrote $OUT_PATH"
