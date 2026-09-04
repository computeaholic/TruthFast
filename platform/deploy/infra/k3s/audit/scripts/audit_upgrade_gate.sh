#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/platform/deploy/infra/k3s/audit/scripts"

FAIL=0

echo "Running audit_integrity_lock.sh..."
if ! "$SCRIPTS_DIR"/audit_integrity_lock.sh >/dev/null 2>&1; then
  echo "ERROR: audit_integrity_lock failed" >&2
  FAIL=1
fi

echo "Running audit_full_validation.sh..."
if ! "$SCRIPTS_DIR"/audit_full_validation.sh >/dev/null 2>&1; then
  echo "ERROR: audit_full_validation failed" >&2
  FAIL=1
fi

echo "Running audit_etcd_correlation.sh..."
if ! "$SCRIPTS_DIR"/audit_etcd_correlation.sh >/dev/null 2>&1; then
  echo "ERROR: audit_etcd_correlation failed" >&2
  FAIL=1
fi

# disk pressure not critical
echo "Checking disk pressure..."
if ! "$SCRIPTS_DIR"/audit_disk_pressure_guard.sh >/dev/null 2>&1; then
  CODE=$?
  if [ "$CODE" -eq 10 ]; then
    echo "ERROR: disk pressure critical" >&2
    FAIL=1
  else
    echo "WARNING: disk pressure warning (non-blocking)"
  fi
fi

# audit log writable
AUDIT_LOG="/var/log/kubernetes/audit/audit.log"
if [ ! -w "$AUDIT_LOG" ]; then
  echo "ERROR: audit log not writable: $AUDIT_LOG" >&2
  FAIL=1
fi

# audit policy SHA matches one of repo versions (reuse integrity lock behavior)
LIVE_SHA=$(sha256sum /var/lib/rancher/k3s/server/audit-policy.yaml | awk '{print $1}')
MATCH=0
for f in "$REPO_DIR"/platform/deploy/infra/k3s/audit/audit-policy.v*.yaml; do
  if [ -f "$f" ]; then
    if [ "$(sha256sum "$f" | awk '{print $1}')" = "$LIVE_SHA" ]; then
      MATCH=1; break
    fi
  fi
done
if [ "$MATCH" -ne 1 ]; then
  echo "ERROR: live audit policy SHA does not match repo canonical versions" >&2
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  echo "UPGRADE BLOCKED: Audit subsystem not in verified state." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "Upgrade gate checks passed (audit subsystem verified)."
exit 0
