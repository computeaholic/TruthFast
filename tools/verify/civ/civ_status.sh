#!/usr/bin/env bash
# requires_identity=true  # trust_tier=full
if ! bash platform/runtime/operator/identity_enforcer.sh --require-full >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires a full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

set -euo pipefail

NAMESPACE=threadforge-system
POD=$(
  kubectl -n ${NAMESPACE} get pods -l app=clickhouse -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
)
if [ -z "$POD" ]; then
  echo "[ERROR] No ClickHouse pod found in namespace ${NAMESPACE}." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

CLICKHOUSE_CMD() {
  kubectl -n ${NAMESPACE} exec -i $POD -- clickhouse-client -q "$1"
}

echo "CIV STATUS — $(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "1) value_plane.operator_ledger — row count:"
CLICKHOUSE_CMD "SELECT count() FROM value_plane.operator_ledger"

echo "\n2) value_plane.cost_model — row count:"
CLICKHOUSE_CMD "SELECT count() FROM value_plane.cost_model"

echo "\n3) value_plane.denial_cost — row count:"
CLICKHOUSE_CMD "SELECT count() FROM value_plane.denial_cost"

echo "\n4) value_plane.operator_ledger — max(created_at):"
CLICKHOUSE_CMD "SELECT toString(max(created_at)) FROM value_plane.operator_ledger"

echo "\nNote: This output is authoritative for Civ truth presence."
