#!/usr/bin/env bash
# tools/dev/demo/move_last_identity_artifact.sh
# Move the most recent identity-enrichment artifact directory into a target directory

set -euo pipefail

TARGET_DIR="$1"
ARTIFACT_ROOT="artifacts/civ/identity-enrichment-test"
mkdir -p "$TARGET_DIR"

shopt -s nullglob
candidates=()
for candidate in "$ARTIFACT_ROOT"/????????T??????Z; do
	if [ -d "$candidate" ]; then
		candidates+=("$candidate")
	fi
done

LAST_DIR=""
if [ "${#candidates[@]}" -gt 0 ]; then
	LAST_DIR=$(printf '%s\n' "${candidates[@]}" | sort | tail -n1)
fi
if [ -z "$LAST_DIR" ]; then
  echo "No identity enrichment artifacts found to move"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
BASE=$(basename "$LAST_DIR")
mv "$LAST_DIR" "$TARGET_DIR/$BASE"
echo "Moved $LAST_DIR -> $TARGET_DIR/$BASE"
