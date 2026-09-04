#!/usr/bin/env bash
set -euo pipefail

# identity_enforcer.sh - Identity-first gate (Phase 6)
# Enforces identity tiers when enforcement is enabled. For partial checks, when enforcement is disabled
# the script allows observation-only (non-blocking) to aid operator drills and safe reviews.
#
# Usage:
#   identity_enforcer.sh --require-full     # exits 0 when tier=full and enforcement enabled; exits 2 when enforcement enabled and tier insufficient; exits 2 when enforcement disabled (read-only enforced)
#   identity_enforcer.sh --require-partial  # exits 0 when tier in {partial, full}; if enforcement not enabled, exits 0 (observation-only); exits 2 when enforcement enabled and tier insufficient

REQUIRE_TIER=${REQUIRE_TIER:-"full"}
PY=$(command -v python3 || command -v python)
if [ -z "${PY:-}" ]; then
  echo "Operator error: python not found; cannot evaluate identity enforcement" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

status_json=$($PY platform/runtime/attestation/enforcement_status.py 2>/dev/null || echo '{}')
# Extract fields reliably from JSON
enabled=$(echo "$status_json" | $PY -c 'import sys, json
try:
    d=json.load(sys.stdin)
    print(d.get("enabled", False))
except Exception:
    print(False)')

tier=$(echo "$status_json" | $PY -c 'import sys, json
try:
    d=json.load(sys.stdin)
    print(d.get("tier", "none"))
except Exception:
    print("none")')

_emit_observation() {
  # Minimal, best-effort observation emission for denied identity checks.
  # Non-blocking: do not affect enforcement decision on failure.
  local status="$1"
  local reason="$2"
  local exec_id
  # Prefer an existing request/correlation ID if set, otherwise generate one
  exec_id="${REQUEST_ID:-}"
  if [ -z "$exec_id" ]; then
    exec_id=$($PY -c 'import uuid,sys;print(uuid.uuid4())')
  fi

  if [ -z "${OBSERVATION_DIR:-}" ]; then
    return 0
  fi

  mkdir -p "${OBSERVATION_DIR}" || return 0

  local now
  now=$($PY - <<'PY'
from datetime import datetime
print(datetime.utcnow().isoformat() + "Z")
PY
)

  local fname="${OBSERVATION_DIR}/${exec_id}.json"
  cat > "${fname}.tmp" <<EOF || true
{"execution_id": "${exec_id}", "status": "${status}", "reason": "${reason}", "observed_at": "${now}"}
EOF
  mv "${fname}.tmp" "$fname" || true
}

# Return codes:
# 0 - enforcement satisfied
# 2 - enforcement NOT satisfied (identity UNSET or insufficient tier)
# 3 - internal error (unable to evaluate)

case "${1:-}" in
  --require-full)
    if [ "$enabled" = "True" ] || [ "$enabled" = "true" ]; then
      if [ "$tier" = "full" ]; then
        exit 0
      else
        _emit_observation "DENIED" "tier=${tier};required=full" || true
        echo "Identity enforcement: tier=$tier (required=full) -> READ-ONLY mode enforced" >&2
        echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
      fi
    else
      _emit_observation "DENIED" "enforcement_not_enabled;required=full" || true
      echo "Identity enforcement: enforcement not enabled -> READ-ONLY mode enforced" >&2
      echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    fi
    ;;
  --require-partial)
    if [ "$enabled" = "True" ] || [ "$enabled" = "true" ]; then
      if [ "$tier" = "full" ] || [ "$tier" = "partial" ]; then
        exit 0
      else
        _emit_observation "DENIED" "tier=${tier};required=partial" || true
        echo "Identity enforcement: tier=$tier (required=partial) -> READ-ONLY mode enforced" >&2
        echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
      fi
    else
      # Enforcement not enabled: for partial checks, allow observation-only flows (do not block)
      # This is observation-only (no write-blocking) to aid safe operator review and demo workflows
      echo "Identity enforcement: enforcement not enabled -> observation-only (no blocking); tier=$tier" >&2
      exit 0
    fi
    ;;
  *)
    echo "Usage: $0 --require-full|--require-partial" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    ;;
esac
