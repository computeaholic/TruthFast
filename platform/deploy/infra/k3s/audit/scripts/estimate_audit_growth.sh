#!/usr/bin/env bash
set -euo pipefail

AUDIT_LOG="/var/log/kubernetes/audit/audit.log"

if [ ! -f "$AUDIT_LOG" ]; then
  echo "ERROR: Audit log not found at $AUDIT_LOG"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "Current audit log size:"
du -h "$AUDIT_LOG"

BYTES=$(stat -c%s "$AUDIT_LOG")
LINES=$(wc -l < "$AUDIT_LOG")

if [ "$LINES" -eq 0 ]; then
  echo "No events recorded yet."
  exit 0
fi

AVG_EVENT_SIZE=$((BYTES / LINES))

echo
echo "Events: $LINES"
echo "Average event size (bytes): $AVG_EVENT_SIZE"

# Estimate hourly growth based on last 5 minutes of log entries
NOW=$(date +%s)
FIVE_MIN_AGO=$((NOW - 300))

RECENT_LINES=$(awk -v ts="$FIVE_MIN_AGO" '
  {
    match($0, /"requestReceivedTimestamp":"([^\"]+)"/, arr)
    if (arr[1] != "") {
      cmd="date -d \"" arr[1] "\" +%s"
      cmd | getline t
      close(cmd)
      if (t >= ts) count++
    }
  }
  END { print count+0 }
' "$AUDIT_LOG")

if [ "$RECENT_LINES" -eq 0 ]; then
  echo "No recent events in last 5 minutes."
  exit 0
fi

EVENTS_PER_MIN=$((RECENT_LINES / 5))
EST_HOURLY_BYTES=$((EVENTS_PER_MIN * 60 * AVG_EVENT_SIZE))

echo
echo "Estimated events/min: $EVENTS_PER_MIN"
echo "Estimated hourly growth: $((EST_HOURLY_BYTES / 1024 / 1024)) MB/hour"
echo "Estimated daily growth: $((EST_HOURLY_BYTES * 24 / 1024 / 1024)) MB/day"
