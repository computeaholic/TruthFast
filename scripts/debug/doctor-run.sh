#!/usr/bin/env bash
set -euo pipefail

# doctor-run.sh - wrapper to run doctor checks with optional strict mode and a summary table
# Usage: MODE=strict ./scripts/doctor-run.sh  OR STRICT=1 ./scripts/doctor-run.sh

STRICT=${STRICT:-0}
if [ "${MODE:-}" = "strict" ]; then STRICT=1; fi

# Propagate STRICT to sub-makes and scripts.
export STRICT

# Doctor authority visibility
echo "Doctor Authority Mode: READ-ONLY (default)"
echo "Telemetry Probe Enabled: ${DOCTOR_ALLOW_PROBE:-0}"

TMPDIR=$(mktemp -d)
RESULTS_FILE="$TMPDIR/doctor_results.json"
> "$RESULTS_FILE"

# CONTRACT -> map of check => mode (GATING or ADVISORY)
# Keep in sync with docs/doctor/CONTRACT.md
check_mode() {
  case "$1" in
    doctor-spire) echo "GATING" ;;
    doctor-collector-check) echo "GATING" ;;
    doctor-telemetry-gate) echo "GATING" ;;
    doctor-config-integrity-gate) echo "GATING" ;;
    doctor-control-plane-gate) echo "GATING" ;;
    doctor-change-authority-gate) echo "GATING" ;;
    *) echo "ADVISORY" ;;
  esac
}

# Doctor is advisory/diagnostic only. Attestors produce attestation results, which operators consume.
# Note: doctor-telemetry (legacy) replaced by doctor-telemetry-gate (GATING) as of 2026-01-26
checks=(doctor-snapshot doctor-spire doctor-istio doctor-observability doctor-telemetry-gate doctor-configs doctor-collector-check doctor-config-integrity-gate doctor-control-plane-gate doctor-change-authority-gate)

echo "[TF] Running doctor checks (strict=$STRICT)"

if [ "$STRICT" -eq 0 ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " GATING CHECKS INACTIVE (strict=0)"
  echo " Contract violations will be reported but will not block execution."
  echo " Run with MODE=strict or STRICT=1 to enable gating enforcement."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
fi

# Provide a DRILL_ID for evidence bundling if not set by the operator.
# This does not grant authority; it only names artifacts.
if [ -z "${DRILL_ID:-}" ]; then
  export DRILL_ID="doctor-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi

overall_status=0
advisory_gating_fail=0

for c in "${checks[@]}"; do
  mode=$(check_mode "$c")
  echo "→ Running $c (mode: $mode)"

  if make -s -C . "$c" STRICT="$STRICT" DRILL_ID="$DRILL_ID" >/tmp/doctor_check_out 2>&1; then
    res=PASS
    notes=""
  else
    res=FAIL
    notes="$(sed -n '1,200p' /tmp/doctor_check_out)"
  fi

  reported_result="$res"
  if [ "$res" = "FAIL" ] && [ "$mode" = "GATING" ]; then
    if [ "$STRICT" -eq 1 ]; then
      echo ""
      echo "⛔ FAIL (execution blocked): $c"
      sed -n '1,200p' /tmp/doctor_check_out || true
      echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    else
      reported_result="GATING (advisory mode) — contract violation detected (strict mode not enabled)"
      advisory_gating_fail=1
    fi
  fi

  notes_json=$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<<"$notes")
  printf '{"check":"%s","mode":"%s","result":"%s","reported_result":"%s","notes":%s}\n' \
    "$c" "$mode" "$res" "$reported_result" "$notes_json" >> "$RESULTS_FILE"

done

# Print summary table
printf "\n%-30s | %-8s | %-70s | %s\n" "Check name" "Mode" "Result" "Notes"
printf "%-30s-+-%-8s-+-%-70s-+-%s\n" "------------------------------" "--------" "----------------------------------------------------------------------" "--------------------------------------------------"

jq -c -r '. | @base64' "$RESULTS_FILE" | while read -r line; do
  rec=$(echo "$line" | base64 --decode)
  check=$(echo "$rec" | jq -r .check)
  mode=$(echo "$rec" | jq -r .mode)
  result=$(echo "$rec" | jq -r '.reported_result // .result')
  notes=$(echo "$rec" | jq -r .notes)
  shortnotes=$(echo "$notes" | sed -n '1,1p' | cut -c1-60)
  printf "%-30s | %-8s | %-70s | %s\n" "$check" "$mode" "$result" "$shortnotes"
done

# Cleanup is mutation. In advisory mode, if any gating check failed, do not attempt cleanup.
if [ "$STRICT" -eq 0 ] && [ "$advisory_gating_fail" -eq 1 ]; then
  # Advisory mode: do not attempt cleanup after any gating failure.
  # Only claim identity insufficiency when the substrate is actually not full.
  status_json=$(python3 platform/runtime/attestation/enforcement_status.py 2>/dev/null || echo '{}')
  enabled=$(echo "$status_json" | python3 -c 'import sys, json
try:
    d=json.load(sys.stdin)
    print(str(d.get("enabled", False)).lower())
except Exception:
    print("false")')
  tier=$(echo "$status_json" | python3 -c 'import sys, json
try:
    d=json.load(sys.stdin)
    print(d.get("tier", "none"))
except Exception:
    print("none")')

  echo ""
  if [ "$enabled" = "true" ] && [ "$tier" = "full" ]; then
    echo "Contract violations detected — probe/environment did not satisfy gating contract (no cleanup)"
  else
    echo "Identity insufficient (READ_ONLY) — gating checks cannot execute"
  fi
else
  if ! bash scripts/debug/doctor-clean.sh >/tmp/doctor_clean_out 2>&1; then
    echo ""
    echo "⚠️  Doctor cleanup reported leftover resources:"
    sed -n '1,200p' /tmp/doctor_clean_out || true
    echo "Advisory: cleanup failures do not block in Doctor (Doctor is non-authoritative)."
    overall_status=$(( overall_status>1 ? overall_status : 1 ))
  fi
fi

if [ "$overall_status" -eq 0 ] && [ "$advisory_gating_fail" -eq 1 ]; then
  echo ""
  echo "⚠️  Doctor completed — contract violations present (running in advisory mode, strict mode not enabled)"
  exit 0
elif [ "$overall_status" -eq 0 ]; then
  echo ""
  echo "✅ Doctor complete: all checks passed (mode=$( [ "$STRICT" -eq 1 ] && echo strict || echo advisory ))"
  exit 0
elif [ "$overall_status" -eq 1 ]; then
  echo ""
  echo "⚠️  Doctor completed with advisory findings (non-gating checks)."
  exit 0
else
  echo ""
  echo "⛔ FAIL: Execution blocked by gating contract violations (strict mode)."
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
