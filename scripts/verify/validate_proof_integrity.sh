#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

STATUS_FILE="artifacts/proof/status.json"
TMP_OUTPUT="$(mktemp)"
MODE="${VALIDATE_PROOF_INTEGRITY_MODE:-full}"
trap 'rm -f "$TMP_OUTPUT"' EXIT

if [[ "$MODE" == "light" ]]; then
  echo "[integrity] running light proof sequence"
  make proof
  make proof-determinism
else
  echo "[integrity] running canonical proof sequence"
  make proof
  make proof-determinism
  make prove-active
  make forgesec
fi

mkdir -p artifacts/proof/latest
git rev-parse HEAD > artifacts/proof/latest/commit.sha

if [[ ! -f "$STATUS_FILE" ]]; then
  echo "[FAIL] missing proof status artifact: $STATUS_FILE"
  exit 2
fi

FINAL="$(jq -r '(.final // "UNKNOWN")' "$STATUS_FILE")"
DETERMINISM="$(jq -r 'if .determinism_verified == true then "PASS" else "FAIL" end' "$STATUS_FILE")"
ACTIVE_GUARANTEES="$(jq -r '(.active_guarantees // "UNKNOWN")' "$STATUS_FILE")"
RBAC_RESOLUTION="$(jq -r '(.completion_record.guarantees.rbac_resolution.status // .rbac_resolution // .guarantees.rbac_resolution.status // "UNKNOWN")' "$STATUS_FILE")"
AUDIT_LOGGING="$(jq -r '(.completion_record.guarantees.audit_logging.status // .audit_logging // .guarantees.audit_logging.status // "UNKNOWN")' "$STATUS_FILE")"
TENANT_ISOLATION="$(jq -r '(.completion_record.guarantees.tenant_isolation.status // .tenant_isolation // .guarantees.tenant_isolation.status // "UNKNOWN")' "$STATUS_FILE")"

echo "FINAL=${FINAL}"
echo "DETERMINISM=${DETERMINISM}"
echo "ACTIVE_GUARANTEES=${ACTIVE_GUARANTEES}"
echo "RBAC_RESOLUTION=${RBAC_RESOLUTION}"
echo "AUDIT_LOGGING=${AUDIT_LOGGING}"
echo "TENANT_ISOLATION=${TENANT_ISOLATION}"

if [[ "$FINAL" != "PASS" ]]; then
  echo "[FAIL] proof integrity gate failed: FINAL != PASS"
  exit 2
fi
if [[ "$DETERMINISM" != "PASS" ]]; then
  echo "[FAIL] proof integrity gate failed: DETERMINISM != PASS"
  exit 2
fi
if [[ "$MODE" != "light" ]]; then
  if [[ "$ACTIVE_GUARANTEES" != "PASS" ]]; then
    echo "[FAIL] proof integrity gate failed: ACTIVE_GUARANTEES != PASS"
    exit 2
  fi
  if [[ "$RBAC_RESOLUTION" != "PASS" ]]; then
    echo "[FAIL] proof integrity gate failed: RBAC_RESOLUTION != PASS"
    exit 2
  fi
  if [[ "$AUDIT_LOGGING" != "PASS" ]]; then
    echo "[FAIL] proof integrity gate failed: AUDIT_LOGGING != PASS"
    exit 2
  fi
  if [[ "$TENANT_ISOLATION" != "PASS" ]]; then
    echo "[FAIL] proof integrity gate failed: TENANT_ISOLATION != PASS"
    exit 2
  fi
fi

if [[ "$MODE" != "light" ]]; then
  echo "[integrity] rerunning determinism check"
  set +e
  make proof-determinism | tee "$TMP_OUTPUT"
  DET_RC=$?
  set -e
  if [[ "$DET_RC" -ne 0 ]]; then
    echo "HASHES_MATCH=false"
    echo "[FAIL] proof determinism rerun failed"
    exit 2
  fi

  if ! grep -q "determinism: artifact hashes match" "$TMP_OUTPUT"; then
    echo "HASHES_MATCH=false"
    echo "[FAIL] proof determinism rerun did not emit canonical hash match evidence"
    exit 2
  fi
fi

echo "HASHES_MATCH=true"
echo "[PASS] validate-proof-integrity complete"
