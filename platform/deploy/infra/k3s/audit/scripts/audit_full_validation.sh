#!/usr/bin/env bash
set -euo pipefail

RC_SUM=0

echo "Running audit-check..."
./scripts/validate_k3s_audit_runtime.sh || RC_SUM=1

echo "Running audit-guard..."
./platform/deploy/infra/k3s/audit/scripts/audit_log_guard.sh || RC_SUM=1

echo "Running audit-disk-guard..."
./platform/deploy/infra/k3s/audit/scripts/audit_disk_pressure_guard.sh || RC_SUM=1

echo "Running audit-estimate..."
./platform/deploy/infra/k3s/audit/scripts/estimate_audit_growth.sh || RC_SUM=1

if [ "$RC_SUM" -eq 0 ]; then
  echo "AUDIT_SYSTEM_STATUS=OK"
  exit 0
else
  echo "AUDIT_SYSTEM_STATUS=DEGRADED"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
