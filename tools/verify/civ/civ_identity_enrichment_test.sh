#!/usr/bin/env bash
# requires_identity=true  # trust_tier=partial

if ! bash platform/runtime/operator/identity_enforcer.sh --require-partial >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires partial or full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

# tools/verify/civ/civ_identity_enrichment_test.sh
# Read-only, deterministic Identity Enrichment test (SELECT-only)

set -euo pipefail

# This script performs linear, provenance-preserving attribution from pod->namespace->operator_ledger->identity_class
# It reports coverage per evidence table and produces bounded, deterministic identity-scoped aggregates when attribution exists.

CH_DB="value_plane"
EVIDENCE_TABLES=("memory_usage_snapshots" "network_metrics" "io_metrics")
OP_LEDGER="operator_ledger"

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

# Check operator_ledger presence
if [ "$(has_table "$CH_DB" "$OP_LEDGER")" = "1" ]; then
  ol_rows=$(run_scalar "SELECT count() FROM ${CH_DB}.${OP_LEDGER}") || ol_rows=0
else
  ol_rows=0
fi

# Totals
total_provenance_rows=0
total_identity_attributed_rows=0
# Use memory_usage_snapshots distinct pod|namespace as total_rows when available
if [ "$(has_table "$CH_DB" "memory_usage_snapshots")" = "1" ]; then
  total_rows=$(run_scalar "SELECT count(DISTINCT concat(namespace, '|', pod)) FROM ${CH_DB}.memory_usage_snapshots") || total_rows=0
else
  total_rows=0
fi
# identity blocking reasons counters
count_block_operator_ledger_missing=0
count_block_present_no_match=0
count_block_not_authoritative=0

# For each evidence table, compute attribution coverage and sample
first=true
for tbl in "${EVIDENCE_TABLES[@]}"; do
  if [ "$(has_table "$CH_DB" "$tbl")" = "1" ]; then
    rows=$(run_scalar "SELECT count() FROM ${CH_DB}.${tbl}") || rows=0
    earliest=$(run_scalar "SELECT toString(min(ts)) FROM ${CH_DB}.${tbl}") || earliest="null"
    latest=$(run_scalar "SELECT toString(max(ts)) FROM ${CH_DB}.${tbl}") || latest="null"

    # attribution counts: left join to operator_ledger by pod/namespace, count attributed vs unattributed
    # compute provenance attribution (distinct pod & namespace)
    provenance_rows=$(run_scalar "SELECT count(DISTINCT concat(namespace, '|', pod)) FROM ${CH_DB}.${tbl}") || provenance_rows=0

    attributed=$(run_scalar "SELECT count(DISTINCT concat(t.namespace, '|', t.pod)) FROM ${CH_DB}.${tbl} t LEFT JOIN (SELECT JSONExtractString(payload,'pod') AS pod, JSONExtractString(payload,'namespace') AS namespace, identity_class FROM ${CH_DB}.${OP_LEDGER} GROUP BY pod, namespace, identity_class) ol ON t.pod = ol.pod AND t.namespace = ol.namespace WHERE ol.identity_class IS NOT NULL AND ol.identity_class != ''") || attributed=0

    unattributed=$(run_scalar "SELECT count(DISTINCT concat(t.namespace, '|', t.pod)) FROM ${CH_DB}.${tbl} t LEFT JOIN (SELECT JSONExtractString(payload,'pod') AS pod, JSONExtractString(payload,'namespace') AS namespace, identity_class FROM ${CH_DB}.${OP_LEDGER} GROUP BY pod, namespace, identity_class) ol ON t.pod = ol.pod AND t.namespace = ol.namespace WHERE ol.identity_class IS NULL OR ol.identity_class = ''") || unattributed=0

    # accumulate totals
    total_provenance_rows=$((total_provenance_rows + provenance_rows))
    total_identity_attributed_rows=$((total_identity_attributed_rows + attributed))
    # total_rows is anchored to distinct pods in memory_usage_snapshots and is not accumulated across tables

    # put entries into COVERAGE.json
    if [ "$first" = true ]; then
      first=false
    fi
    printf "  \"%s\": {\"status\": \"present\", \"rows\": %s, \"earliest_ts\": %s, \"latest_ts\": %s, \"retention_window_days\": null, \"notes\": \"aggregated from %s.%s\", \"attributed_rows\": %s, \"unattributed_rows\": %s, \"provenance_attributed_rows\": %s},\n" "$tbl" "$rows" "\"$earliest\"" "\"$latest\"" "$CH_DB" "$tbl" "$attributed" "$unattributed" "$provenance_rows" >> "$COVERAGE_FILE"

    # produce a bounded RAW_IDENTITY_ENRICHMENT.csv sample (identity-scoped aggregates)
    kubectl -n threadforge-system exec -i sts/clickhouse -- clickhouse-client --format=CSVWithNames -q "SELECT ol.identity_class, t.namespace, t.pod, count() AS rows FROM ${CH_DB}.${tbl} t LEFT JOIN (SELECT JSONExtractString(payload,'pod') AS pod, JSONExtractString(payload,'namespace') AS namespace, identity_class FROM ${CH_DB}.${OP_LEDGER} GROUP BY pod, namespace, identity_class) ol ON t.pod = ol.pod AND t.namespace = ol.namespace GROUP BY ol.identity_class, t.namespace, t.pod ORDER BY rows DESC, ol.identity_class ASC NULLS LAST, t.namespace ASC, t.pod ASC LIMIT 200" > RAW_IDENTITY_ENRICHMENT.csv || true

    # Enhance RAW sample with identity_blocking_reason (bounded, deterministic). If operator_ledger is missing globally, mark all as operator_ledger_missing
    if [ "${ol_rows}" -eq 0 ]; then
      # operator_ledger missing globally
      if [ -f RAW_IDENTITY_ENRICHMENT.csv ]; then
        awk -F"," 'BEGIN{OFS=","} NR==1{print $0, "identity_blocking_reason"} NR>1{print $0, "operator_ledger_missing"}' RAW_IDENTITY_ENRICHMENT.csv > RAW_IDENTITY_ENRICHMENT_WITH_REASON.csv || true
        mv RAW_IDENTITY_ENRICHMENT_WITH_REASON.csv RAW_IDENTITY_ENRICHMENT.csv || true
        # increment global counter using provenance_rows (not sample size)
        count_block_operator_ledger_missing=$((count_block_operator_ledger_missing + provenance_rows))
      fi
    else
      # operator_ledger present: compute per-table blocking counts using observed evidence
      # count of rows where namespace has at least one mapping but pod does not
      ns_present_no_match=$(run_scalar "SELECT count(DISTINCT concat(t.namespace, '|', t.pod)) FROM ${CH_DB}.${tbl} t WHERE (SELECT count() FROM ${CH_DB}.${OP_LEDGER} ol WHERE JSONExtractString(ol.payload,'namespace') = t.namespace AND ol.identity_class != '') > 0 AND (SELECT count() FROM ${CH_DB}.${OP_LEDGER} ol WHERE JSONExtractString(ol.payload,'pod') = t.pod AND JSONExtractString(ol.payload,'namespace') = t.namespace AND ol.identity_class != '') = 0") || ns_present_no_match=0
      count_block_present_no_match=$((count_block_present_no_match + ns_present_no_match))
      # remaining provenance rows without pod match or namespace match are not authoritative
      not_auth=$((provenance_rows - attributed - ns_present_no_match))
      if [ "$not_auth" -lt 0 ]; then
        not_auth=0
      fi
      count_block_not_authoritative=$((count_block_not_authoritative + not_auth))

      # Now produce per-row reason in the RAW sample for reviewer inspection (bounded, deterministic)
      if [ -f RAW_IDENTITY_ENRICHMENT.csv ]; then
        awk -F"," 'NR==1{print $0, "identity_blocking_reason"; next} {printf "%s,%s,%s,%s\n", $1, $2, $3, $4}' RAW_IDENTITY_ENRICHMENT.csv > RAW_IDENTITY_ENRICHMENT_TMP.csv || true
        # replace REASON_PLACEHOLDER by querying operator_ledger for each row (sample only)
        > RAW_IDENTITY_ENRICHMENT_WITH_REASON.csv || true
        sed -n '2,200p' RAW_IDENTITY_ENRICHMENT_TMP.csv | while IFS= read -r line; do
          pod=$(echo "$line" | awk -F"," '{gsub(/"/,"",$3); print $3}')
          ns=$(echo "$line" | awk -F"," '{gsub(/"/,"",$2); print $2}')
          # check pod-level mapping
          pod_match=$(run_scalar "SELECT count() FROM ${CH_DB}.${OP_LEDGER} WHERE JSONExtractString(payload,'pod') = '${pod}' AND JSONExtractString(payload,'namespace') = '${ns}' AND identity_class != ''") || pod_match=0
          if [ "$pod_match" -gt 0 ]; then
            reason="identity_attributed"
          else
            ns_match=$(run_scalar "SELECT count() FROM ${CH_DB}.${OP_LEDGER} WHERE JSONExtractString(payload,'namespace') = '${ns}' AND identity_class != ''") || ns_match=0
            if [ "$ns_match" -gt 0 ]; then
              reason="operator_ledger_present_no_match"
            else
              reason="identity_system_not_authoritative_for_namespace"
            fi
          fi
          # output line with reason
          echo "${line},\"${reason}\"" >> RAW_IDENTITY_ENRICHMENT_WITH_REASON.csv || true
        done
        # prepend header
        head -n 1 RAW_IDENTITY_ENRICHMENT.csv | awk -F"," '{OFS=","; print $1,$2,$3,$4,"identity_blocking_reason"}' > RAW_IDENTITY_ENRICHMENT_FINAL.csv || true
        cat RAW_IDENTITY_ENRICHMENT_WITH_REASON.csv >> RAW_IDENTITY_ENRICHMENT_FINAL.csv || true
        mv RAW_IDENTITY_ENRICHMENT_FINAL.csv RAW_IDENTITY_ENRICHMENT.csv || true
      fi
    fi
  else
    # absent table
    if [ "$first" = true ]; then
      first=false
    fi
    printf "  \"%s\": {\"status\": \"absent\", \"rows\": 0, \"earliest_ts\": null, \"latest_ts\": null, \"retention_window_days\": null, \"notes\": \"table %s.%s not found\", \"attributed_rows\": 0, \"unattributed_rows\": 0},\n" "$tbl" "$CH_DB" "$tbl" >> "$COVERAGE_FILE"
  fi
done

# Operator ledger presence entry
if [ "$(has_table "$CH_DB" "$OP_LEDGER")" = "1" ]; then
  printf "  \"%s\": {\"status\": \"present\", \"rows\": %s, \"notes\": \"operator ledger with identity mappings\"},\n" "$OP_LEDGER" "$ol_rows" >> "$COVERAGE_FILE"
else
  printf "  \"%s\": {\"status\": \"absent\", \"rows\": 0, \"notes\": \"table %s.%s not found\"},\n" "$OP_LEDGER" "$CH_DB" "$OP_LEDGER" >> "$COVERAGE_FILE"
fi

# Add overall attribution totals and blocking reasons
blocked_json="[]"
if [ "$ol_rows" -eq 0 ]; then
  blocked_json='["missing_operator_ledger_mapping"]'
fi

printf "  \"provenance_attributed_rows\": %s,\n  \"identity_attributed_rows\": %s,\n  \"identity_attribution_blocked_by\": %s,\n  \"identity_blocking_reasons\": {\"operator_ledger_missing\": %s, \"operator_ledger_present_no_match\": %s, \"identity_system_not_authoritative_for_namespace\": %s}\n" "$total_provenance_rows" "$total_identity_attributed_rows" "$blocked_json" "$count_block_operator_ledger_missing" "$count_block_present_no_match" "$count_block_not_authoritative" >> "$COVERAGE_FILE"

printf "}\n" >> "$COVERAGE_FILE"

# Emit human-readable output
cat <<EOF
This artifact is advisory only. It performs provenance-preserving, SELECT-only identity enrichment by joining evidence tables to operator_ledger mappings (pod -> namespace -> operator_ledger -> identity_class). Attribution is opt-in and best-effort; missing mappings and missing evidence are surfaced in COVERAGE.json. No inference, heuristics, or fallback logic is performed.

Coverage report written to ${COVERAGE_FILE}.

If RAW_IDENTITY_ENRICHMENT.csv exists it contains bounded, deterministic identity-scoped aggregates (identity_class may be null when attribution is missing).

ATTRIBUTION PROVENANCE REPORT

Required attribution signals
Required for identity attribution:
- pod
- namespace
- operator_ledger mapping (pod, namespace -> identity_class)

Observed signal coverage
Observed signals:
- pod present: ${total_provenance_rows} / ${total_rows}
- namespace present: ${total_provenance_rows} / ${total_rows}
- operator_ledger mappings present: ${ol_rows} / ${total_rows}

Attribution results
Provenance-attributed rows: ${total_provenance_rows} / ${total_rows}
Identity-attributed rows: ${total_identity_attributed_rows} / ${total_rows}

Root cause
EOF

if [ "${ol_rows}" -eq 0 ]; then
  cat <<'EOF'
Identity attribution failed due to absence of operator_ledger mappings.
EOF
elif [ "${total_rows}" -eq 0 ]; then
  cat <<'EOF'
Identity attribution had no evidence rows to attribute, even though operator_ledger mappings were present.
EOF
else
  cat <<'EOF'
Identity attribution found evidence rows but no authoritative pod/namespace mappings matched them.
EOF
fi

cat <<EOF
No inference or fallback attribution was performed.

Identity attribution blocking reasons:
- operator_ledger_missing: ${count_block_operator_ledger_missing}
- operator_ledger_present_no_match: ${count_block_present_no_match}
- identity_system_not_authoritative_for_namespace: ${count_block_not_authoritative}

Example pods missing identity mapping:
EOF

# Evidence listing (bounded, deterministic)
if [ "$(has_table "$CH_DB" "memory_usage_snapshots")" = "1" ]; then
  kubectl -n threadforge-system exec -i sts/clickhouse -- clickhouse-client --format=CSVWithNames -q "SELECT t.pod, t.namespace, count() AS rows FROM ${CH_DB}.memory_usage_snapshots t LEFT JOIN (SELECT JSONExtractString(payload,'pod') AS pod, JSONExtractString(payload,'namespace') AS namespace, identity_class FROM ${CH_DB}.${OP_LEDGER} GROUP BY pod, namespace, identity_class) ol ON t.pod = ol.pod AND t.namespace = ol.namespace WHERE ol.identity_class IS NULL OR ol.identity_class = '' GROUP BY t.namespace, t.pod ORDER BY t.namespace ASC, t.pod ASC LIMIT 10" > UNATTRIBUTED_PODS.csv || true
  if [ -f UNATTRIBUTED_PODS.csv ]; then
    sed -n '1,11p' UNATTRIBUTED_PODS.csv | sed -n '2,11p' | awk -F"," '{printf "- %s (%s)\n", $1, $2}'
  fi
fi

jq . "$COVERAGE_FILE" || cat "$COVERAGE_FILE"

if [ -f RAW_IDENTITY_ENRICHMENT.csv ]; then
  echo "\nRAW sample (first 10 lines):"
  sed -n '1,11p' RAW_IDENTITY_ENRICHMENT.csv || true
fi

exit 0
