#!/usr/bin/env bash
# scripts/check_to_fu_apply.sh
# Exit 0 if no 'tofu apply' occurrences are found; exit non-zero and print matches if found.
set -euo pipefail
shopt -s globstar 2>/dev/null || true
GREP=${GREP:-grep}
# Exclude common binary and vendor directories
EXCLUDE_DIRS=(.git node_modules .venv .venv* build dist .terraform vendor .venv)
# Build exclude patterns
EXCLUDE_ARGS=()
for d in "${EXCLUDE_DIRS[@]}"; do
  EXCLUDE_ARGS+=(--exclude-dir="$d")
done
# Search for 'tofu apply' (case-insensitive) in repo
matches=$($GREP -RIn -- "tofu apply" -- "./" ${EXCLUDE_ARGS[@]} || true)
if [ -n "$matches" ]; then
  echo "FOUND 'tofu apply' occurrences:" >&2
  echo "$matches" >&2
  echo "[ADVISORY-FAIL] non-authoritative path" >&2
  exit 2
fi
exit 0
