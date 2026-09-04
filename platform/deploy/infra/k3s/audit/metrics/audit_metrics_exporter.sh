#!/usr/bin/env bash
set -euo pipefail

AUDIT_LOG="/var/log/kubernetes/audit/audit.log"
TAIL_LINES=50000

if [ ! -f "$AUDIT_LOG" ]; then
  echo "ERROR: Audit log not found at $AUDIT_LOG" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

BYTES=$(stat -c%s "$AUDIT_LOG")
LINES=$(wc -l < "$AUDIT_LOG")
if [ "$LINES" -eq 0 ]; then
  AVG_EVENT_SIZE=0
else
  AVG_EVENT_SIZE=$((BYTES / LINES))
fi

# Estimate hourly/daily based on recent activity (last 5 minutes)
NOW=$(date +%s)
FIVE_MIN_AGO=$((NOW - 300))

# Extract recent lines count by scanning for requestReceivedTimestamp occurrences in the last N lines
RECENT_LINES=$(tail -n "$TAIL_LINES" "$AUDIT_LOG" | awk -v ts="$FIVE_MIN_AGO" '
  {
    if (match($0, /"requestReceivedTimestamp":"([^\"]+)"/, arr)) {
      cmd = "date -d \"" arr[1] "\" +%s"
      cmd | getline t
      close(cmd)
      if (t >= ts) count++
    }
  }
  END { print count+0 }
')

if [ "$RECENT_LINES" -eq 0 ]; then
  EVENTS_PER_MIN=0
else
  EVENTS_PER_MIN=$((RECENT_LINES / 5))
fi
EST_HOURLY_BYTES=$((EVENTS_PER_MIN * 60 * AVG_EVENT_SIZE))
EST_DAILY_BYTES=$((EST_HOURLY_BYTES * 24))

# Find most recent RequestResponse timestamp (epoch seconds) using pattern search (no jq required)
LAST_RR_TS=$(tac "$AUDIT_LOG" | awk '
  {
    if (match($0, /RequestResponse/ ) || match($0, /"requestObject"/) || match($0, /"responseObject"/)) {
      if (match($0, /"requestReceivedTimestamp":"([^\"]+)"/, arr)) {
        cmd = "date -d \"" arr[1] "\" +%s"
        cmd | getline t
        close(cmd)
        print t
        exit
      }
      if (match($0, /"timestamp":"([^\"]+)"/, arr)) {
        cmd = "date -d \"" arr[1] "\" +%s"
        cmd | getline t
        close(cmd)
        print t
        exit
      }
    }
  }
') || true

# Output Prometheus text format
cat <<EOF
# HELP audit_log_size_bytes Current size of audit log
# TYPE audit_log_size_bytes gauge
audit_log_size_bytes $BYTES

# HELP audit_log_event_count Total events in audit log
# TYPE audit_log_event_count gauge
audit_log_event_count $LINES

# HELP audit_log_avg_event_size_bytes Average event size in bytes
# TYPE audit_log_avg_event_size_bytes gauge
audit_log_avg_event_size_bytes $AVG_EVENT_SIZE

# HELP audit_log_estimated_hourly_bytes Estimated hourly byte growth
# TYPE audit_log_estimated_hourly_bytes gauge
audit_log_estimated_hourly_bytes $EST_HOURLY_BYTES

# HELP audit_log_estimated_daily_bytes Estimated daily byte growth
# TYPE audit_log_estimated_daily_bytes gauge
audit_log_estimated_daily_bytes $EST_DAILY_BYTES

# HELP audit_log_last_requestresponse_timestamp Epoch seconds of most recent RequestResponse-like event
# TYPE audit_log_last_requestresponse_timestamp gauge
audit_log_last_requestresponse_timestamp ${LAST_RR_TS:-0}
EOF
