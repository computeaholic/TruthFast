#!/usr/bin/env bash
# requires_identity=true  # trust_tier=full
# tools/verify/civ/demo_load_identity_authority.sh
# Demo-only loader: inserts deterministic operator_ledger rows for authorized identity demonstration

if ! bash platform/runtime/operator/identity_enforcer.sh --require-full >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires a full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

set -euo pipefail

SQL_FILE="/workspace/tools/verify/civ/demo_identity_authority.sql"
# Use kubectl to run a check and insert if not already present
exists=$(kubectl -n threadforge-system exec -i sts/clickhouse -- clickhouse-client -q "SELECT count() FROM value_plane.operator_ledger_v2 WHERE source_ledger = 'demo-identity-authority'" 2>/dev/null || echo "0")
if [ "$exists" = "0" ]; then
  echo "Loading demo identity authority into value_plane.operator_ledger_v2"
  # Pipe the SQL file to clickhouse-client via stdin to avoid argument-quoting issues and potential hangs
  kubectl -n threadforge-system exec -i sts/clickhouse -- clickhouse-client --multiquery < tools/verify/civ/demo_identity_authority.sql
  echo "Demo identity authority loaded"
else
  echo "Demo identity authority already present (count=$exists)"
fi
