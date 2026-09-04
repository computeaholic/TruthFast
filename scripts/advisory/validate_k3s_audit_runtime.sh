#!/usr/bin/env bash
set -euo pipefail

LIVE_PATH="/var/lib/rancher/k3s/server/audit-policy.yaml"
AUDIT_LOG="/var/log/kubernetes/audit/audit.log"

echo "Checking k3s process..."
if ! pgrep -x k3s >/dev/null; then
  echo "ERROR: k3s process not running" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "Checking k3s process args for audit-policy-file..."
PSARGS=$(ps -o args= -p "$(pgrep -x k3s)")
if echo "$PSARGS" | grep -q "audit-policy-file=/var/lib/rancher/k3s/server/audit-policy.yaml"; then
  echo "k3s started with audit-policy-file arg: OK"
else
  echo "WARNING: k3s does not appear to have audit-policy-file argument" >&2
fi

echo "Checking audit log file exists and non-zero..."
if [ ! -f "$AUDIT_LOG" ]; then
  echo "ERROR: Audit log file not present: $AUDIT_LOG" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
if [ ! -s "$AUDIT_LOG" ]; then
  echo "ERROR: Audit log file is empty: $AUDIT_LOG" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "Extracting most recent high-signal RequestResponse event..."
EVENT=$(tail -n 50000 "$AUDIT_LOG" | \
  jq -c 'select(.level=="RequestResponse") | select(.stage=="ResponseComplete")' | \
  tail -n1 || true)

if [ -z "$EVENT" ]; then
  echo "No recent RequestResponse mutation events found."
  exit 0
fi

echo "Most recent mutation event:"
echo "$EVENT" | jq -r '{
  time: .stageTimestamp,
  verb: .verb,
  user: .user.username,
  resource: .objectRef.resource,
  namespace: .objectRef.namespace,
  name: .objectRef.name
}'
