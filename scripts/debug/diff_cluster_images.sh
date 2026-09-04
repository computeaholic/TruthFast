#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME_PATH="${1:-$REPO_ROOT/artifacts/runtime/runtime_images.txt}"
DECLARED_PATH="${2:-$REPO_ROOT/artifacts/runtime/declared_images.txt}"
DIFF_PATH="${3:-$REPO_ROOT/artifacts/runtime/cluster_images.diff}"

if [ ! -f "$RUNTIME_PATH" ]; then
  echo "[FAIL] missing runtime image inventory: $RUNTIME_PATH" >&2
  exit 2
fi

if [ ! -f "$DECLARED_PATH" ]; then
  echo "[FAIL] missing declared image inventory: $DECLARED_PATH" >&2
  exit 2
fi

runtime_tmp="$(mktemp)"
declared_tmp="$(mktemp)"
cleanup() {
  rm -f "$runtime_tmp" "$declared_tmp"
}
trap cleanup EXIT

sed -n 's/^  .* image=//p' "$RUNTIME_PATH" | sed '/^$/d' | sed 's/[[:space:]]//g' | sort -u > "$runtime_tmp"
sed '/^$/d' "$DECLARED_PATH" | sed 's/[[:space:]]//g' | sort -u > "$declared_tmp"

if diff -u "$declared_tmp" "$runtime_tmp" > "$DIFF_PATH"; then
  cat "$DIFF_PATH"
  exit 0
fi

cat "$DIFF_PATH"
exit 1
