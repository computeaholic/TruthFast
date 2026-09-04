#!/usr/bin/env bash
# requires_identity=true  # trust_tier=partial
# tools/verify/civ/civ_network_governance_test.sh

if ! bash platform/runtime/operator/identity_enforcer.sh --require-partial >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires partial or full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi
# Runs SELECT-only checks for Network Governance Lens and emits deterministic artifacts to stdout.

set -euo pipefail

# This script is SELECT-only and advisory. It must not mutate or collect new data.

# Check presence of expected tables
CH_TABLE_DB="value_plane"
NET_TABLE="network_metrics"
CONN_TABLE="connection_metrics"

has_table() {
  local db=$1
  local tbl=$2
  kubectl -n threadforge-system exec -i sts/clickhouse -- clickhouse-client -q "SELECT count() FROM system.tables WHERE database='${db}' AND name='${tbl}'" 2>/dev/null || echo "0"
}

# Helper to run a query and return single scalar
run_scalar() {
  local q=$1
  kubectl -n threadforge-system exec -i sts/clickhouse -- clickhouse-client -q "${q}" 2>/dev/null || true
}

# Create a minimal JSON coverage report to stdout
COVERAGE_FILE="COVERAGE.json"

# Start building coverage object
printf "{\n" > "$COVERAGE_FILE"

# bytes_sent / bytes_received coverage
if [ "$(has_table "$CH_TABLE_DB" "$NET_TABLE")" = "1" ]; then
  rows=$(run_scalar "SELECT count() FROM ${CH_TABLE_DB}.${NET_TABLE}") || rows=0
  if [ -z "$rows" ]; then rows=0; fi
  earliest=$(run_scalar "SELECT toString(min(ts)) FROM ${CH_TABLE_DB}.${NET_TABLE}") || earliest="null"
  latest=$(run_scalar "SELECT toString(max(ts)) FROM ${CH_TABLE_DB}.${NET_TABLE}") || latest="null"
  printf "  \"bytes_sent\": {\"status\": \"present\", \"rows\": %s, \"earliest_ts\": %s, \"latest_ts\": %s, \"retention_window_days\": null, \"notes\": \"aggregated from %s.%s\"},\n" "$rows" "\"$earliest\"" "\"$latest\"" "$CH_TABLE_DB" "$NET_TABLE" >> "$COVERAGE_FILE"
  printf "  \"bytes_received\": {\"status\": \"present\", \"rows\": %s, \"earliest_ts\": %s, \"latest_ts\": %s, \"retention_window_days\": null, \"notes\": \"aggregated from %s.%s\"},\n" "$rows" "\"$earliest\"" "\"$latest\"" "$CH_TABLE_DB" "$NET_TABLE" >> "$COVERAGE_FILE"

  # Attempt to produce a small RAW_NETWORK.csv sample
  kubectl -n threadforge-system exec -i sts/clickhouse -- clickhouse-client --format=CSVWithNames -q "SELECT identity_class, namespace, pod, sum(bytes_sent) AS bytes_sent, sum(bytes_received) AS bytes_received, min(ts) AS earliest_ts, max(ts) AS latest_ts FROM ${CH_TABLE_DB}.${NET_TABLE} GROUP BY identity_class, namespace, pod ORDER BY bytes_sent DESC LIMIT 200" > RAW_NETWORK.csv || true
else
  printf "  \"bytes_sent\": {\"status\": \"absent\", \"rows\": 0, \"earliest_ts\": null, \"latest_ts\": null, \"retention_window_days\": null, \"notes\": \"table %s.%s not found\"},\n" "$CH_TABLE_DB" "$NET_TABLE" >> "$COVERAGE_FILE"
  printf "  \"bytes_received\": {\"status\": \"absent\", \"rows\": 0, \"earliest_ts\": null, \"latest_ts\": null, \"retention_window_days\": null, \"notes\": \"table %s.%s not found\"},\n" "$CH_TABLE_DB" "$NET_TABLE" >> "$COVERAGE_FILE"
fi

# connections coverage
if [ "$(has_table "$CH_TABLE_DB" "$CONN_TABLE")" = "1" ]; then
  rows=$(run_scalar "SELECT count() FROM ${CH_TABLE_DB}.${CONN_TABLE}") || rows=0
  earliest=$(run_scalar "SELECT toString(min(ts)) FROM ${CH_TABLE_DB}.${CONN_TABLE}") || earliest="null"
  latest=$(run_scalar "SELECT toString(max(ts)) FROM ${CH_TABLE_DB}.${CONN_TABLE}") || latest="null"
  printf "  \"connections\": {\"status\": \"present\", \"rows\": %s, \"earliest_ts\": %s, \"latest_ts\": %s, \"retention_window_days\": null, \"notes\": \"aggregated from %s.%s\"}\n" "$rows" "\"$earliest\"" "\"$latest\"" "$CH_TABLE_DB" "$CONN_TABLE" >> "$COVERAGE_FILE"
else
  printf "  \"connections\": {\"status\": \"absent\", \"rows\": 0, \"earliest_ts\": null, \"latest_ts\": null, \"retention_window_days\": null, \"notes\": \"table %s.%s not found\"}\n" "$CH_TABLE_DB" "$CONN_TABLE" >> "$COVERAGE_FILE"
fi

printf "}\n" >> "$COVERAGE_FILE"

# Emit human-readable output to stdout
cat <<EOF
This artifact is advisory only. It surfaces observed network signals, coverage gaps, and uncertainty; it does not perform enforcement, prediction, or inference.

Coverage report written to ${COVERAGE_FILE}.

If RAW_NETWORK.csv exists it contains a bounded, deterministic sample of identity-scoped aggregates (identity_class may be null when attribution is missing).
EOF

# Also print a short summary for convenience
jq . "$COVERAGE_FILE" || cat "$COVERAGE_FILE"

# Print RAW_NETWORK sample head if present
if [ -f RAW_NETWORK.csv ]; then
  echo "\nRAW sample (first 10 lines):"
  sed -n '1,11p' RAW_NETWORK.csv || true
fi

# Exit success (missing signals are surfaced, not errors)
exit 0
