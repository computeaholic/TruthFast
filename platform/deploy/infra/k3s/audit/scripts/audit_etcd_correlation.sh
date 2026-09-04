#!/usr/bin/env bash
set -euo pipefail

SNAP_DIR="/var/lib/rancher/k3s/server/db/snapshots"
AUDIT_LOG="/var/log/kubernetes/audit/audit.log"
SNAP_MAX_AGE_SECONDS=${SNAP_MAX_AGE_SECONDS:-86400} # default tolerance (24h)

if [ ! -d "$SNAP_DIR" ]; then
  echo "ERROR: etcd snapshot directory missing: $SNAP_DIR" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# find latest snapshot file (by mtime)
LATEST_SNAP=$(ls -1t "$SNAP_DIR" 2>/dev/null | head -n1 || true)
if [ -z "$LATEST_SNAP" ]; then
  echo "ERROR: no etcd snapshots found in $SNAP_DIR" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
LATEST_SNAP_PATH="$SNAP_DIR/$LATEST_SNAP"
SNAP_TS=$(stat -c %Y "$LATEST_SNAP_PATH")

# extract most recent RequestResponse timestamp from audit log
if [ ! -f "$AUDIT_LOG" ]; then
  echo "ERROR: audit log missing: $AUDIT_LOG" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

LAST_RR_TS=$(tac "$AUDIT_LOG" | awk '
  {
    if (match($0, /"requestReceivedTimestamp":"([^\"]+)"/, arr)) {
      cmd = "date -d \"" arr[1] "\" +%s"
      cmd | getline t; close(cmd)
      print t; exit
    }
    if (match($0, /"timestamp":"([^\"]+)"/, arr)) {
      cmd = "date -d \"" arr[1] "\" +%s"
      cmd | getline t; close(cmd)
      print t; exit
    }
  }
' || true)

if [ -z "$LAST_RR_TS" ]; then
  echo "ERROR: failed to parse most recent RequestResponse timestamp" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Compare
if [ "$LAST_RR_TS" -gt "$SNAP_TS" ]; then
  echo "WARNING: Audit activity newer than latest etcd snapshot"
  echo "latest_snapshot=$LATEST_SNAP_PATH"
  echo "snapshot_ts=$SNAP_TS"
  echo "last_requestresponse_ts=$LAST_RR_TS"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Check snapshot age tolerance
NOW=$(date +%s)
AGE=$((NOW - SNAP_TS))
if [ "$AGE" -gt "$SNAP_MAX_AGE_SECONDS" ]; then
  echo "WARNING: Latest snapshot older than tolerance ($SNAP_MAX_AGE_SECONDS seconds)"
  echo "latest_snapshot=$LATEST_SNAP_PATH"
  echo "snapshot_ts=$SNAP_TS"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# OK
echo "etcd_snapshot_present=ok"
echo "latest_snapshot=$LATEST_SNAP_PATH"
echo "snapshot_ts=$SNAP_TS"
echo "last_requestresponse_ts=$LAST_RR_TS"
exit 0
