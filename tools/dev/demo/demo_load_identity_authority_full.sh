#!/usr/bin/env bash
# requires_identity=true  # trust_tier=full
# tools/dev/demo/demo_load_identity_authority_full.sh
# Demo-only loader: generates and inserts deterministic full authority operator_ledger rows

if ! bash platform/runtime/operator/identity_enforcer.sh --require-full >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires a full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

set -euo pipefail

TMP_SQL_FILE="$(mktemp -t threadforge-demo-authority.XXXXXX.sql)"
SQL_FILE="${DEMO_FULL_SQL_FILE:-${TMP_SQL_FILE}}"
cleanup() {
	if [[ -z "${DEMO_FULL_SQL_FILE:-}" ]]; then
		rm -f "${TMP_SQL_FILE}"
	fi
}
trap cleanup EXIT

# Generate SQL deterministically from observed namespaces
DEMO_FULL_SQL_OUTPUT="${SQL_FILE}" ./tools/dev/demo/generate_full_demo_sql.sh

# Check if already present
exists=$(kubectl -n threadforge-system exec -i sts/clickhouse -- clickhouse-client -q "SELECT count() FROM value_plane.operator_ledger_v2 WHERE source_ledger = 'demo-authority-full'" 2>/dev/null || echo "0")
if [ "$exists" = "0" ]; then
  echo "Loading full demo identity authority into value_plane.operator_ledger_v2"
  # Pipe the SQL file to clickhouse-client via stdin to avoid argument-quoting issues and potential hangs
  kubectl -n threadforge-system exec -i sts/clickhouse -- clickhouse-client --multiquery < "$SQL_FILE"
  echo "Demo full identity authority loaded"
else
  echo "Demo full identity authority already present (count=$exists)"
fi
