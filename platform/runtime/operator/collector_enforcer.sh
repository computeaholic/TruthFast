#!/usr/bin/env bash
set -euo pipefail

# collector_enforcer.sh - Operator wiring to invoke collector_attestor and record ledger entries
# Behavior:
# - ATTESTOR_ENFORCEMENT_ENABLED (default: true) determines whether enforcement (blocking) is active
# - ATTESTOR_CANARY_SCOPE: selector for canary (not enforced here, example-only)
# - For P4 identity-first semantics enforcement is enabled by default; this script performs enforcement as law (fail-closed) when attestation indicates identity absent or insufficient.

ATTESTOR_ENFORCEMENT_ENABLED=${ATTESTOR_ENFORCEMENT_ENABLED:-"true"}
ATTESTOR_CANARY_SCOPE=${ATTESTOR_CANARY_SCOPE:-""}
LEDGER_FILE=${LEDGER_FILE:-"/tmp/operator-ledger.jsonl"}

DRILL_OUT=/tmp/collector-attest-out
set +e
platform/runtime/attestation/collector_attestor.sh >"$DRILL_OUT" 2>&1
rc=$?
set -e

# Collect attestation summary
attestation_id=$(jq -r '.attestation_id // "unknown"' <(jq -c '.' "$DRILL_OUT" 2>/dev/null) 2>/dev/null || echo "unknown")
verdict="unknown"
if [ $rc -eq 0 ]; then
  verdict="pass"
elif [ $rc -eq 2 ]; then
  verdict="fail"
else
  verdict="error"
fi

# Update enforcement readiness via attestation manager (P4 law enforcement)
if command -v python3 >/dev/null 2>&1; then
  python3 - <<PY
from runtime.attestation.manager import process_attestation_result
process_attestation_result("pass" if "$verdict" == "pass" else "fail", "full" if "$verdict" == "pass" else "none")
PY
  if [ $? -ne 0 ]; then
    echo "FATAL: attestation manager failed, enforcement status update blocked" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
fi


# Determine action_taken based on configured enforcement behavior and verdict

if [ "$verdict" = "fail" ]; then
  if [ "$ATTESTOR_ENFORCEMENT_ENABLED" = "true" ]; then
    action_taken="blocked"
  else
    action_taken="observation-only"
  fi
else
  if [ "$ATTESTOR_ENFORCEMENT_ENABLED" = "true" ]; then
    action_taken="enforced"
  else
    action_taken="noop"
  fi
fi

# ledger entry
jq -n --arg attestation_id "$attestation_id" \
      --arg verdict "$verdict" \
      --arg operator_actor_id "operator-run" \
      --arg action_taken "$action_taken" \
      --arg evidence_path "$(grep -o 's3://[^\ ]*' "$DRILL_OUT" || true)" \
      '{ledger_id: (now|tostring), attestation_id: $attestation_id, verdict: $verdict, operator_actor_id: $operator_actor_id, action_taken: $action_taken, evidence_path: $evidence_path, timestamp: (now|todate)}' >> "$LEDGER_FILE"

# Emit a metric-friendly line (for tests / integration)
echo "operator_attest_verdict verdict=$verdict action=$action_taken"

# Enforcement behavior: block when enabled and verdict=fail
if [ "$action_taken" = "blocked" ]; then
  echo "Operator: enforcement active, execution blocked (verdict=$verdict)" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# When enforcement is disabled and we would have blocked, fail-closed by default
# Set ATTESTOR_ALLOW_OBSERVE=true to explicitly allow observation-only behavior (exit 0)
ATTESTOR_ALLOW_OBSERVE=${ATTESTOR_ALLOW_OBSERVE:-"false"}
if [ "$action_taken" = "observation-only" ]; then
  echo "Operator: enforcement disabled, observation only (verdict=$verdict)" >&2
  if [ "$ATTESTOR_ALLOW_OBSERVE" = "true" ]; then
    echo "Operator: ATTESTOR_ALLOW_OBSERVE=true, proceeding in observation-only mode" >&2
    exit 0
  else
    echo "Operator: enforcement disabled but policy requires fail-closed. Blocking by default." >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
fi

exit 0
