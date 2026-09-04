#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_PATH="${VALUE_PLANE_AUDIT_ARTIFACT:-$REPO_ROOT/artifacts/audit/value_plane_audit.json}"

query_scalar() {
  local query="$1"
  kubectl -n threadforge-system exec sts/clickhouse -- \
    clickhouse-client --format=TSVRaw -q "$query" | tr -d '[:space:]'
}

required_tables="$(query_scalar "SELECT count() FROM system.tables WHERE database = 'value_plane' AND name IN ('operator_ledger', 'operator_ledger_v2', 'value_ledger', 'value_ledger_v2')")"
duplicate_rows="$(query_scalar "SELECT count() FROM (SELECT source_ledger, source_event_id FROM value_plane.operator_ledger GROUP BY source_ledger, source_event_id HAVING count(*) > 1)")"
null_identity_rows="$(query_scalar "SELECT count() FROM value_plane.operator_ledger WHERE identity_class = '' OR (spiffe_id = '' AND source_ledger NOT IN ('demo-identity-authority', 'demo-identity-authority-full'))")"
missing_lineage_rows="$(query_scalar "SELECT count() FROM value_plane.operator_ledger WHERE source_event_id IS NULL OR ingest_run_id IS NULL OR ingested_at IS NULL")"

status="PASS"
failures=()
if [[ "$required_tables" != "4" ]]; then
  status="FAIL"
  failures+=("required_tables=${required_tables}")
fi
if [[ "$duplicate_rows" != "0" ]]; then
  status="FAIL"
  failures+=("duplicate_rows=${duplicate_rows}")
fi
if [[ "$null_identity_rows" != "0" ]]; then
  status="FAIL"
  failures+=("null_identity_rows=${null_identity_rows}")
fi
if [[ "$missing_lineage_rows" != "0" ]]; then
  status="FAIL"
  failures+=("missing_lineage_rows=${missing_lineage_rows}")
fi

source_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
cluster_context="$(kubectl config current-context)"
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$(dirname "$ARTIFACT_PATH")"

"${REPO_ROOT}/.venv/bin/python" - \
  "$ARTIFACT_PATH" "$status" "$source_sha" "$cluster_context" "$generated_at" \
  "$required_tables" "$duplicate_rows" "$null_identity_rows" "$missing_lineage_rows" \
  "${failures[*]:-}" <<'PY'
import json
import pathlib
import sys

(
    artifact_path,
    status,
    source_sha,
    cluster_context,
    generated_at,
    required_tables,
    duplicate_rows,
    null_identity_rows,
    missing_lineage_rows,
    failures,
) = sys.argv[1:]

payload = {
    "schema_version": 1,
    "status": status,
    "verify_type": "READ_ONLY",
    "source_sha": source_sha,
    "cluster_context": cluster_context,
    "generated_at": generated_at,
    "checks": {
        "required_tables": {"expected": 4, "actual": int(required_tables)},
        "duplicate_rows": {"expected": 0, "actual": int(duplicate_rows)},
        "null_identity_rows": {"expected": 0, "actual": int(null_identity_rows)},
        "missing_lineage_rows": {"expected": 0, "actual": int(missing_lineage_rows)},
    },
    "controlled_fixture_exclusions": [
        "demo-identity-authority",
        "demo-identity-authority-full",
    ],
    "failures": failures.split() if failures else [],
}
path = pathlib.Path(artifact_path)
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

echo "VALUE_PLANE_AUDIT_STATUS=${status}"
echo "VALUE_PLANE_AUDIT_ARTIFACT=${ARTIFACT_PATH}"
if [[ "$status" != "PASS" ]]; then
  printf '[FAIL] value-plane audit: %s\n' "${failures[*]}" >&2
  exit 2
fi
echo "[PASS] value-plane audit: required tables, uniqueness, identity, and lineage invariants hold"
