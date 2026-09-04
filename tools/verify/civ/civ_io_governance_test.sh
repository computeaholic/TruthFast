#!/usr/bin/env bash
# requires_identity=true  # trust_tier=partial
# tools/verify/civ/civ_io_governance_test.sh
# Runs SELECT-only checks for IO Governance Lens and emits deterministic artifacts to stdout.

if ! bash platform/runtime/operator/identity_enforcer.sh --require-partial >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires partial or full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

set -euo pipefail

CH_TABLE_DB="value_plane"
IO_TABLE="io_metrics"
IO_WAIT_TABLE="io_wait_metrics"

has_table() {
  local db=$1
  local tbl=$2
  kubectl -n threadforge-system exec -i sts/clickhouse -- clickhouse-client -q "SELECT count() FROM system.tables WHERE database='${db}' AND name='${tbl}'" 2>/dev/null || echo "0"
}

run_scalar() {
  local q=$1
  kubectl -n threadforge-system exec -i sts/clickhouse -- clickhouse-client -q "${q}" 2>/dev/null || true
}

COVERAGE_FILE="COVERAGE.json"
printf "{\n" > "$COVERAGE_FILE"

if [ "$(has_table "$CH_TABLE_DB" "$IO_TABLE")" = "1" ]; then
  rows=$(run_scalar "SELECT count() FROM ${CH_TABLE_DB}.${IO_TABLE}") || rows=0
  earliest=$(run_scalar "SELECT toString(min(ts)) FROM ${CH_TABLE_DB}.${IO_TABLE}") || earliest="null"
  latest=$(run_scalar "SELECT toString(max(ts)) FROM ${CH_TABLE_DB}.${IO_TABLE}") || latest="null"
  printf "  \"disk_read_bytes\": {\"status\": \"present\", \"rows\": %s, \"earliest_ts\": %s, \"latest_ts\": %s, \"retention_window_days\": null, \"notes\": \"aggregated from %s.%s\"},\n" "$rows" "\"$earliest\"" "\"$latest\"" "$CH_TABLE_DB" "$IO_TABLE" >> "$COVERAGE_FILE"
  printf "  \"disk_write_bytes\": {\"status\": \"present\", \"rows\": %s, \"earliest_ts\": %s, \"latest_ts\": %s, \"retention_window_days\": null, \"notes\": \"aggregated from %s.%s\"},\n" "$rows" "\"$earliest\"" "\"$latest\"" "$CH_TABLE_DB" "$IO_TABLE" >> "$COVERAGE_FILE"

  kubectl -n threadforge-system exec -i sts/clickhouse -- clickhouse-client --format=CSVWithNames -q "SELECT identity_class, namespace, pod, sum(disk_read_bytes) AS disk_read_bytes, sum(disk_write_bytes) AS disk_write_bytes, min(ts) AS earliest_ts, max(ts) AS latest_ts FROM ${CH_TABLE_DB}.${IO_TABLE} GROUP BY identity_class, namespace, pod ORDER BY disk_read_bytes DESC LIMIT 200" > RAW_IO.csv || true
else
  printf "  \"disk_read_bytes\": {\"status\": \"absent\", \"rows\": 0, \"earliest_ts\": null, \"latest_ts\": null, \"retention_window_days\": null, \"notes\": \"table %s.%s not found\"},\n" "$CH_TABLE_DB" "$IO_TABLE" >> "$COVERAGE_FILE"
  printf "  \"disk_write_bytes\": {\"status\": \"absent\", \"rows\": 0, \"earliest_ts\": null, \"latest_ts\": null, \"retention_window_days\": null, \"notes\": \"table %s.%s not found\"},\n" "$CH_TABLE_DB" "$IO_TABLE" >> "$COVERAGE_FILE"
fi

if [ "$(has_table "$CH_TABLE_DB" "$IO_WAIT_TABLE")" = "1" ]; then
  rows=$(run_scalar "SELECT count() FROM ${CH_TABLE_DB}.${IO_WAIT_TABLE}") || rows=0
  earliest=$(run_scalar "SELECT toString(min(ts)) FROM ${CH_TABLE_DB}.${IO_WAIT_TABLE}") || earliest="null"
  latest=$(run_scalar "SELECT toString(max(ts)) FROM ${CH_TABLE_DB}.${IO_WAIT_TABLE}") || latest="null"
  printf "  \"io_wait_ms\": {\"status\": \"present\", \"rows\": %s, \"earliest_ts\": %s, \"latest_ts\": %s, \"retention_window_days\": null, \"notes\": \"aggregated from %s.%s\"}\n" "$rows" "\"$earliest\"" "\"$latest\"" "$CH_TABLE_DB" "$IO_WAIT_TABLE" >> "$COVERAGE_FILE"
else
  printf "  \"io_wait_ms\": {\"status\": \"absent\", \"rows\": 0, \"earliest_ts\": null, \"latest_ts\": null, \"retention_window_days\": null, \"notes\": \"table %s.%s not found\"}\n" "$CH_TABLE_DB" "$IO_WAIT_TABLE" >> "$COVERAGE_FILE"
fi

printf "}\n" >> "$COVERAGE_FILE"

cat <<EOF
This artifact is advisory only. It surfaces observed IO signals, coverage gaps, and uncertainty; it does not perform enforcement, prediction, or inference.

Coverage report written to ${COVERAGE_FILE}.

If RAW_IO.csv exists it contains a bounded, deterministic sample of identity-scoped IO aggregates (identity_class may be null when attribution is missing).
EOF

jq . "$COVERAGE_FILE" || cat "$COVERAGE_FILE"

if [ -f RAW_IO.csv ]; then
  echo "\nRAW sample (first 10 lines):"
  sed -n '1,11p' RAW_IO.csv || true
fi

exit 0
