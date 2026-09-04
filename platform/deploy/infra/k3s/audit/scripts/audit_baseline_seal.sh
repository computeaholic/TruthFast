#!/usr/bin/env bash
set -euo pipefail

OUT_FILE="/home/threadforge/threadforge/platform/deploy/infra/k3s/audit/AUDIT_BASELINE_SEAL.json"
LIVE_POLICY="/var/lib/rancher/k3s/server/audit-policy.yaml"
AUDIT_LOG="/var/log/kubernetes/audit/audit.log"
SNAP_DIR="/var/lib/rancher/k3s/server/db/snapshots"
DRY_RUN=0

if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
fi

# helpers
json_null() { jq -n 'null'; }

if [ ! -f "$LIVE_POLICY" ]; then
  echo "ERROR: live policy missing: $LIVE_POLICY" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

POLICY_SHA=$(sha256sum "$LIVE_POLICY" | awk '{print $1}')
PSARGS=$(ps -o args= -p "$(pgrep -x k3s || true)" 2>/dev/null || true)
INODE=$(stat -c %i "$AUDIT_LOG" 2>/dev/null || echo "null")
DEVICE=$(stat -c %d "$AUDIT_LOG" 2>/dev/null || echo "null")
DF_PERCENT=$(df -P "$AUDIT_LOG" | awk 'NR==2{gsub(/%/,"",$5); print 100-$5}')
HOSTNAME=$(hostname)
K3S_VERSION="unknown"
if command -v k3s >/dev/null 2>&1; then
  K3S_VERSION=$(k3s --version 2>/dev/null | head -n1 || echo "$K3S_VERSION")
fi

# etcd latest snapshot
LATEST_SNAP=""
SNAP_TS=""
if [ -d "$SNAP_DIR" ]; then
  LATEST_SNAP=$(ls -1t "$SNAP_DIR" 2>/dev/null | head -n1 || true)
  if [ -n "$LATEST_SNAP" ]; then
    SNAP_TS=$(stat -c %Y "$SNAP_DIR/$LATEST_SNAP")
  fi
fi

# recent RequestResponse timestamp
RECENT_RR_TS=""
if [ -f "$AUDIT_LOG" ]; then
  RECENT_RR_TS=$(tac "$AUDIT_LOG" | awk '
    {
      if (match($0, /"requestReceivedTimestamp":"([^\"]+)"/, arr)) {
        cmd = "date -d \"" arr[1] "\" +%s"; cmd | getline t; close(cmd); print t; exit
      }
      if (match($0, /"timestamp":"([^\"]+)"/, arr)) {
        cmd = "date -d \"" arr[1] "\" +%s"; cmd | getline t; close(cmd); print t; exit
      }
    }
  ' || true)
fi

TIMESTAMP=$(date --iso-8601=seconds)

# Build JSON with jq
# rotation chain info
LEDGER="/home/threadforge/threadforge/platform/deploy/infra/k3s/audit/AUDIT_ROTATION_LEDGER.jsonl"
rotation_chain_latest_hash=null
rotation_chain_length=0
if [ -f "$LEDGER" ] && [ -s "$LEDGER" ]; then
  rotation_chain_latest_hash=$(tail -n1 "$LEDGER" | jq -r '.chain_hash')
  rotation_chain_length=$(wc -l < "$LEDGER" | tr -d ' ')
fi

BASE_JSON=$(jq -n \
  --arg timestamp "$TIMESTAMP" \
  --arg policy_sha256 "$POLICY_SHA" \
  --arg k3s_process_args "$PSARGS" \
  --arg audit_log_inode "$INODE" \
  --arg audit_log_device "$DEVICE" \
  --arg disk_available_percent "$DF_PERCENT" \
  --arg etcd_latest_snapshot "$LATEST_SNAP" \
  --arg etcd_snapshot_timestamp "$SNAP_TS" \
  --arg recent_requestresponse_timestamp "${RECENT_RR_TS:-}" \
  --arg hostname "$HOSTNAME" \
  --arg k3s_version "$K3S_VERSION" \
  --arg rotation_chain_latest_hash "$rotation_chain_latest_hash" \
  --argjson rotation_chain_length "$rotation_chain_length" \
  '{timestamp:$timestamp,policy_sha256:$policy_sha256,k3s_process_args:$k3s_process_args,audit_log_inode:$audit_log_inode,audit_log_device:$audit_log_device,disk_available_percent:$disk_available_percent,etcd_latest_snapshot:$etcd_latest_snapshot,etcd_snapshot_timestamp:$etcd_snapshot_timestamp,recent_requestresponse_timestamp:$recent_requestresponse_timestamp,hostname:$hostname,k3s_version:$k3s_version,rotation_chain_latest_hash:$rotation_chain_latest_hash,rotation_chain_length:$rotation_chain_length}')

# Compute SHA and append
BASE_SHA=$(echo "$BASE_JSON" | jq -c . | sha256sum | awk '{print $1}')
FINAL_JSON=$(echo "$BASE_JSON" | jq --arg baseline_sha256 "$BASE_SHA" '. + {baseline_sha256:$baseline_sha256}')

if [ "$DRY_RUN" -eq 1 ]; then
  echo "$FINAL_JSON" | jq .
  exit 0
fi

# Write file to repo path (operator will commit)
echo "$FINAL_JSON" | jq . > "$OUT_FILE"
chmod 0644 "$OUT_FILE"
echo "WROTE $OUT_FILE"
exit 0
