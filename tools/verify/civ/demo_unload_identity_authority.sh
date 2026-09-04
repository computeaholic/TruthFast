#!/usr/bin/env bash
# tools/verify/civ/demo_unload_identity_authority.sh
# Demo-only cleanup: removes any demo identity authority rows

# requires_identity=true  # trust_tier=full
if ! bash platform/runtime/operator/identity_enforcer.sh --require-full >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires a full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

set -euo pipefail

count=$(kubectl -n threadforge-system exec -i sts/clickhouse -- clickhouse-client -q "SELECT count() FROM value_plane.operator_ledger_v2 WHERE source_ledger = 'demo-identity-authority'" 2>/dev/null || echo "0")
if [ "$count" = "0" ]; then
  echo "No demo identity authority rows found (count=0)"
else
  echo "Removing $count demo identity authority rows from value_plane.operator_ledger_v2"
  kubectl -n threadforge-system exec -i sts/clickhouse -- clickhouse-client -q "ALTER TABLE value_plane.operator_ledger_v2 DELETE WHERE source_ledger = 'demo-identity-authority'"
  echo "Demo identity authority rows removed"
fi
