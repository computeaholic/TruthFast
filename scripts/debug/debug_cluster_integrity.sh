#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_PATH="${1:-$REPO_ROOT/artifacts/debug/cluster_integrity_debug.log}"
DEBUG_DIR="$(dirname "$OUT_PATH")"
DECLARED_OUT_PATH="$REPO_ROOT/artifacts/runtime/declared_images.txt"
RUNTIME_SET_PATH="$REPO_ROOT/artifacts/runtime/runtime_images.txt"
RUNTIME_UNIQUE_PATH="$REPO_ROOT/artifacts/runtime/runtime_unique_images.txt"
KUBECTL_BIN="${KUBECTL_BIN:-$(type -P kubectl || true)}"
COLLECT_SCRIPT="$REPO_ROOT/scripts/supply_chain/collect_images.sh"
ALLOWED_SYSTEM_IMAGES="$REPO_ROOT/scripts/verify/allowed_system_images.txt"

run_kubectl() {
  if [ -z "$KUBECTL_BIN" ]; then
    echo "[FAIL] kubectl binary not found" >&2
    exit 2
  fi
  "$KUBECTL_BIN" "$@"
}

if [ ! -x "$COLLECT_SCRIPT" ]; then
  echo "[FAIL] missing collector: $COLLECT_SCRIPT" >&2
  exit 2
fi

mkdir -p "$DEBUG_DIR"
mkdir -p "$REPO_ROOT/artifacts/runtime"

run_kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{range .spec.containers[*]}{"  container="}{.name}{" image="}{.image}{"\n"}{end}{range .spec.initContainers[*]}{"  init="}{.name}{" image="}{.image}{"\n"}{end}{"\n"}{end}' > "$RUNTIME_SET_PATH"

run_kubectl get pods -A -o jsonpath='{..image}' \
  | tr -s '[:space:]' '\n' \
  | sed '/^$/d' \
  | sort -u > "$RUNTIME_UNIQUE_PATH"

tmp_declared="$(mktemp)"
cleanup() {
  rm -f "$tmp_declared"
}
trap cleanup EXIT

{
  "$COLLECT_SCRIPT" --scope cluster
  if [ -f "$ALLOWED_SYSTEM_IMAGES" ]; then
    cat "$ALLOWED_SYSTEM_IMAGES"
  fi
} | sed '/^\[/d' | sed '/^#/d' | sed '/^$/d' | sort -u > "$tmp_declared"
cp "$tmp_declared" "$DECLARED_OUT_PATH"

{
  echo "=== runtime images (all namespaces) ==="
  echo "command: kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{\"/\"}{.metadata.name}{\"\\n\"}{range .spec.containers[*]}{\"  container=\"}{.name}{\" image=\"}{.image}{\"\\n\"}{end}{range .spec.initContainers[*]}{\"  init=\"}{.name}{\" image=\"}{.image}{\"\\n\"}{end}{\"\\n\"}{end}'"
  cat "$RUNTIME_SET_PATH"
  echo
  echo "=== runtime unique images ==="
  echo "command: kubectl get pods -A -o jsonpath='{..image}' | sort | uniq"
  cat "$RUNTIME_UNIQUE_PATH"
  echo
  echo "=== declared images ==="
  echo "source: scripts/supply_chain/collect_images.sh --scope cluster + scripts/verify/allowed_system_images.txt"
  cat "$DECLARED_OUT_PATH"
} > "$OUT_PATH"

echo "[PASS] wrote $OUT_PATH"
