#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_DIR="/home/threadforge/threadforge/platform/deploy/infra/k3s/audit/scripts"

FAIL=0

if ! "$SCRIPTS_DIR"/audit_verify_rotation_chain.sh >/dev/null 2>&1; then
  echo "rotation-chain-failed" >&2
  FAIL=1
fi

if ! "$SCRIPTS_DIR"/audit_etcd_correlation.sh >/dev/null 2>&1; then
  echo "etcd-correlation-failed" >&2
  FAIL=1
fi

if ! "$SCRIPTS_DIR"/audit_integrity_lock.sh >/dev/null 2>&1; then
  echo "integrity-lock-failed" >&2
  FAIL=1
fi

if ! "$SCRIPTS_DIR"/audit_full_validation.sh >/dev/null 2>&1; then
  echo "full-validation-failed" >&2
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  echo "AUDIT CONTINUITY BROKEN" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "AUDIT CONTINUITY VERIFIED"
exit 0
