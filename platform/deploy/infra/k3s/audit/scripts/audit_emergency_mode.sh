#!/usr/bin/env bash
set -euo pipefail

AUDIT_DIR="/var/log/kubernetes/audit"
if [ ! -d "$AUDIT_DIR" ]; then
  echo "ERROR: Audit dir missing" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

PERC=$(df -P "$AUDIT_DIR" | awk 'NR==2{gsub(/%/,"",$5); print $5}')

if [ "$PERC" -ge 95 ]; then
  echo "EMERGENCY_RECOMMENDATION=SWITCH_POLICY_TO_METADATA_ONLY"
  exit 0
else
  echo "NO_EMERGENCY"
  exit 0
fi
