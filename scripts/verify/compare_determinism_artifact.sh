#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 4 ]]; then
  echo "usage: $0 <json|text> <run1_file> <run2_file> <label>" >&2
  exit 2
fi

kind="$1"
run1_file="$2"
run2_file="$3"
label="$4"

[[ -f "$run1_file" ]] || { echo "[FAIL] NON_DETERMINISM: missing run1 artifact for ${label}: ${run1_file}"; exit 2; }
[[ -f "$run2_file" ]] || { echo "[FAIL] NON_DETERMINISM: missing run2 artifact for ${label}: ${run2_file}"; exit 2; }

case "$kind" in
  json)
    python3 - "$run1_file" "$run2_file" "$label" <<'PY'
import json
import sys
from pathlib import Path

run1 = Path(sys.argv[1])
run2 = Path(sys.argv[2])
label = sys.argv[3]

try:
    doc1 = json.loads(run1.read_text())
    doc2 = json.loads(run2.read_text())
except json.JSONDecodeError as exc:
    print(f"[FAIL] NON_DETERMINISM: invalid JSON for {label}: {exc}")
    raise SystemExit(2)

# audit_logging_validation.json intentionally captures append-only audit stream
# state (e.g. entries/final_hash) that can differ between consecutive proof
# runs while security invariants remain stable. Compare only invariant fields.
if label == "audit_logging_validation.json":
  volatile_keys = {"entries", "final_hash"}
  doc1 = {k: v for k, v in doc1.items() if k not in volatile_keys}
  doc2 = {k: v for k, v in doc2.items() if k not in volatile_keys}

if doc1 != doc2:
    print(f"[FAIL] NON_DETERMINISM: {label} differs between runs")
    raise SystemExit(2)

print(f"[PASS] determinism {label}: identical")
PY
    ;;
  text)
    if ! cmp -s "$run1_file" "$run2_file"; then
      echo "[FAIL] NON_DETERMINISM: ${label} differs between runs"
      exit 2
    fi
    echo "[PASS] determinism ${label}: identical"
    ;;
  *)
    echo "[FAIL] unsupported compare kind: ${kind}" >&2
    exit 2
    ;;
esac
