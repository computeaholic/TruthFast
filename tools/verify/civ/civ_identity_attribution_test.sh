#!/usr/bin/env bash
# requires_identity=true  # trust_tier=partial

if ! bash platform/runtime/operator/identity_enforcer.sh --require-partial >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires partial or full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

# tools/verify/civ/civ_identity_attribution_test.sh
# Read-only, deterministic identity attribution test (SELECT-only)

set -euo pipefail

if [ "$#" -ne 0 ]; then
  echo "ERROR: This script accepts no arguments" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

echo ""
echo "================================================================="
echo " THREADFORGE :: CIV :: IDENTITY ATTRIBUTION TEST (read-only)"
echo "================================================================="

# Attribution summary and aggregates
kubectl -n threadforge-system exec -i sts/clickhouse -- bash << 'EOF'
set -euo pipefail

echo ""
echo "=============================="
echo " THREADFORGE :: IDENTITY ATTRIBUTION DEMO"
echo "=============================="
echo ""

echo "▶ 1) IDENTITY ATTRIBUTION COVERAGE REPORT"
clickhouse-client --format=Pretty << 'SQL'
SELECT
  count() AS total_rows,
  countIf(ol.identity_class != '' AND ol.identity_class IS NOT NULL) AS attributed_rows,
  countIf(ol.identity_class = '' OR ol.identity_class IS NULL) AS unattributed_rows,
  round(100.0 * countIf(ol.identity_class != '' AND ol.identity_class IS NOT NULL) / count(), 2) AS percent_attributed,
  round(100.0 * countIf(ol.identity_class = '' OR ol.identity_class IS NULL) / count(), 2) AS percent_unattributed
FROM value_plane.memory_usage_snapshots m
LEFT JOIN (
  SELECT
    identity_class,
    JSONExtractString(payload, 'pod') AS pod,
    JSONExtractString(payload, 'namespace') AS namespace,
    max(created_at) AS latest_seen
  FROM value_plane.operator_ledger
  GROUP BY identity_class, pod, namespace
) ol
  ON m.pod = ol.pod AND m.namespace = ol.namespace
SQL

echo ""
echo "▶ 2) IDENTITY-SCOPED MEMORY AGGREGATES (WHERE ATTRIBUTED)"
clickhouse-client --format=Pretty << 'SQL'
SELECT
  ol.identity_class,
  sum(m.memory_bytes) AS sum_memory_bytes
FROM value_plane.memory_usage_snapshots m
LEFT JOIN (
  SELECT
    identity_class,
    JSONExtractString(payload, 'pod') AS pod,
    JSONExtractString(payload, 'namespace') AS namespace,
    max(created_at) AS latest_seen
  FROM value_plane.operator_ledger
  GROUP BY identity_class, pod, namespace
) ol
  ON m.pod = ol.pod AND m.namespace = ol.namespace
WHERE ol.identity_class != '' AND ol.identity_class IS NOT NULL
GROUP BY ol.identity_class
ORDER BY sum_memory_bytes DESC
LIMIT 20;
SQL

echo ""
echo "▶ 3) UNCERTAINTY STATEMENT"
echo "All attribution is opt-in, incomplete by design, and surfaced as evidence. Attribution gaps are explicit and no inference is performed."
EOF
