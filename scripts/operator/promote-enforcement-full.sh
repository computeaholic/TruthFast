#!/usr/bin/env bash
set -euo pipefail

# promote-enforcement-full.sh
# Purpose: explicit, operator-invoked promotion from attestation -> enforcement(full).
# Contract:
# - No background execution
# - No retries
# - Idempotent (if already full, exit cleanly)
# - Refuse to run without valid evidence
# - Only setter: runtime.attestation.manager.process_attestation_result("pass", "full")

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then
  echo "ERROR: python not found" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

status_json="$($PY platform/runtime/attestation/enforcement_status.py 2>/dev/null || echo '{}')"
current_enabled=$(echo "$status_json" | $PY -c 'import sys,json
try:
  d=json.load(sys.stdin)
  print(str(d.get("enabled", False)).lower())
except Exception:
  print("false")')
current_tier=$(echo "$status_json" | $PY -c 'import sys,json
try:
  d=json.load(sys.stdin)
  print(d.get("tier", "none"))
except Exception:
  print("none")')

if [ "$current_enabled" = "true" ] && [ "$current_tier" = "full" ]; then
  echo "Enforcement already FULL (no-op)"
  exit 0
fi

ATTESTOR="$REPO_ROOT/platform/runtime/attestation/collector_attestor.sh"
DRILL="$REPO_ROOT/scripts/debug/doctor-drill.sh"

if [ ! -f "$ATTESTOR" ]; then
  echo "ERROR: missing attestor: platform/runtime/attestation/collector_attestor.sh" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
if [ ! -f "$DRILL" ]; then
  echo "ERROR: missing drill: scripts/doctor-drill.sh" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Deterministic (time-based) DRILL_ID; avoids overwriting evidence.
DRILL_ID="promote-$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="/tmp/${DRILL_ID}-evidence"

if [ -e "$EVIDENCE_DIR" ]; then
  echo "ERROR: evidence dir already exists; refusing to overwrite: $EVIDENCE_DIR" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

export DRILL_ID
export EVIDENCE_DIR

echo "Running attestation (DRILL_ID=$DRILL_ID)"
if ! bash "$ATTESTOR" >/tmp/threadforge-promote-attestor.out 2>&1; then
  echo "ERROR: attestation failed" >&2
  sed -n '1,200p' /tmp/threadforge-promote-attestor.out >&2 || true
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

att_json="$EVIDENCE_DIR/attestation.json"
if [ ! -f "$att_json" ]; then
  echo "ERROR: attestation did not produce $att_json" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

att_result=$(cat "$att_json" | $PY -c 'import sys,json
try:
  d=json.load(sys.stdin)
  print(d.get("result", ""))
except Exception:
  print("")')
att_reason=$(cat "$att_json" | $PY -c 'import sys,json
try:
  d=json.load(sys.stdin)
  print(d.get("reason", ""))
except Exception:
  print("")')

if [ "$att_result" != "PASS" ]; then
  echo "ERROR: attestation result not PASS (got: $att_result)" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Full trust eligibility signal: drill succeeded (identity-bound evidence produced).
if [ "$att_reason" != "drill successful" ]; then
  echo "ERROR: attestation did not indicate full-trust eligibility (reason='$att_reason')" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if [ ! -f "$EVIDENCE_DIR/drill.json" ]; then
  echo "ERROR: missing drill evidence: $EVIDENCE_DIR/drill.json" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# The only lawful setter (do not change)
$PY - <<'PY'
from runtime.attestation.manager import process_attestation_result
process_attestation_result("pass", "full")
PY

# Verify enforcement
final_json="$($PY platform/runtime/attestation/enforcement_status.py 2>/dev/null || echo '{}')"
final_enabled=$(echo "$final_json" | $PY -c 'import sys,json
try:
  d=json.load(sys.stdin)
  print(str(d.get("enabled", False)).lower())
except Exception:
  print("false")')
final_tier=$(echo "$final_json" | $PY -c 'import sys,json
try:
  d=json.load(sys.stdin)
  print(d.get("tier", "none"))
except Exception:
  print("none")')

if [ "$final_enabled" != "true" ] || [ "$final_tier" != "full" ]; then
  echo "ERROR: enforcement promotion failed; status=$final_json" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "Enforcement promoted to FULL (identity verified)"
exit 0
