#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENTRIES_FILE="${SPIRE_ENTRIES_FILE:-$REPO_ROOT/platform/identity/spire/entries.yaml}"

python3 "$REPO_ROOT/scripts/debug/normalize_spire_entries.py" "$REPO_ROOT/artifacts/debug/spire_entries_runtime.json" > /tmp/runtime.json
python3 "$REPO_ROOT/scripts/debug/normalize_spire_entries.py" "$ENTRIES_FILE" > /tmp/declared.json

diff -u /tmp/declared.json /tmp/runtime.json || true
