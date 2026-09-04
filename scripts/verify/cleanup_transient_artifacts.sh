#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET_DIR="$REPO_ROOT/artifacts/tmp"
TTL_DAYS="${TRANSIENT_TTL_DAYS:-14}"
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)
      TTL_DAYS="$2"
      shift 2
      ;;
    --check)
      CHECK_ONLY=1
      shift
      ;;
    *)
      echo "Usage: $0 [--days N] [--check]"
      exit 2
      ;;
  esac
done

mkdir -p "$TARGET_DIR"

mapfile -t STALE_FILES < <(find "$TARGET_DIR" -type f -mtime "+${TTL_DAYS}" -print)

if [[ ${#STALE_FILES[@]} -eq 0 ]]; then
  echo "[PASS] no transient artifacts exceeded TTL=${TTL_DAYS}d in artifacts/tmp"
  exit 0
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  echo "[FAIL] stale transient artifacts detected in artifacts/tmp (TTL=${TTL_DAYS}d)"
  for f in "${STALE_FILES[@]}"; do
    echo "  ${f#"$REPO_ROOT"/}"
  done
  exit 2
fi

for f in "${STALE_FILES[@]}"; do
  rm -f "$f"
done

echo "[PASS] removed ${#STALE_FILES[@]} stale transient artifacts from artifacts/tmp (TTL=${TTL_DAYS}d)"
