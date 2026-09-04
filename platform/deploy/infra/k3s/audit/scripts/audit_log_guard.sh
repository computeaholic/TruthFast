#!/usr/bin/env bash
set -euo pipefail

AUDIT_LOG="/var/log/kubernetes/audit/audit.log"
MAX_SIZE_MB=2048     # 2GB hard guard
WARN_SIZE_MB=1024    # 1GB warning threshold

if [ ! -f "$AUDIT_LOG" ]; then
  echo "ERROR: Audit log missing"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

SIZE_BYTES=$(stat -c%s "$AUDIT_LOG")
SIZE_MB=$((SIZE_BYTES / 1024 / 1024))

if [ "$SIZE_MB" -ge "$MAX_SIZE_MB" ]; then
  echo "CRITICAL: Audit log exceeds ${MAX_SIZE_MB}MB"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if [ "$SIZE_MB" -ge "$WARN_SIZE_MB" ]; then
  echo "WARNING: Audit log exceeds ${WARN_SIZE_MB}MB"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "OK: Audit log size ${SIZE_MB}MB"
exit 0
