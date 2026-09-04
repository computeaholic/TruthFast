#!/usr/bin/env bash
set -euo pipefail
source scripts/utils.sh

TARGET="${1:-deploy}"
OUT="forensics/filesystem_snapshot_$(timestamp).txt"

mkdir -p forensics

{
  echo "THREADFORGE FORENSIC SNAPSHOT (NOT AUDIT)"
  echo "Generated: $(timestamp)"
  echo "Target: $TARGET"
  echo

  echo "=== FORENSIC DIRECTORY TREE ==="
  tree "$TARGET"
  echo

  echo "=== FORENSIC FILE INDEX ==="
  find "$TARGET" -type f | sort
  echo

  echo "=== FORENSIC SHA256 INTEGRITY MAP ==="
  sha_tree "$TARGET"
  echo

  echo "=== FORENSIC FILE CONTENTS ==="
  while IFS= read -r f; do
    echo
    echo "----- FILE: $f -----"
    sed 's/\t/  /g' "$f"
  done < <(find "$TARGET" -type f | sort)

} > "$OUT"

echo "[✓] Forensic snapshot written to $OUT"
