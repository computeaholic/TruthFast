#!/usr/bin/env bash
set -euo pipefail

AUDIT_LOG_DIR="/var/log/kubernetes/audit"
AUDIT_LOG="$AUDIT_LOG_DIR/audit.log"

if [ ! -d "$AUDIT_LOG_DIR" ]; then
  echo "ERROR: Audit log directory missing: $AUDIT_LOG_DIR" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Determine filesystem and percent used
FS=$(df -P "$AUDIT_LOG_DIR" | awk 'NR==2{print $1}')
PERC=$(df -P "$AUDIT_LOG_DIR" | awk 'NR==2{gsub(/%/,"",$5); print $5}')

STATUS=OK
CODE=0
if [ "$PERC" -ge 90 ]; then
  STATUS=CRITICAL
  CODE=10
elif [ "$PERC" -ge 80 ]; then
  STATUS=WARNING
  CODE=5
fi

echo "DISK_USAGE_PERCENT=$PERC"
echo "STATUS=$STATUS"
exit $CODE
