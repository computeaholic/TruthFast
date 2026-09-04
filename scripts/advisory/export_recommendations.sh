#!/usr/bin/env bash
# Authority Domain: identity_gated
# requires_identity=true  # trust_tier=full
# Enforce P4 invariant: block execution when identity enforcement is not available
if ! bash platform/runtime/operator/identity_enforcer.sh --require-full >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires a full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

set -euo pipefail

NAMESPACE=threadforge-system
OUT_DIR=artifacts/advisory
TS=$(date -u +"%Y%m%dT%H%M%SZ")

# Guard: ensure SQL file exists and is not empty
if [ ! -s data/queries/advisory/recommendations.sql ]; then
  echo "No advisory recommendations SQL present — skipping export"
  exit 0
fi

mkdir -p "$OUT_DIR"

kubectl -n "$NAMESPACE" exec -i sts/clickhouse -- \
  clickhouse-client --format=CSV \
  < data/queries/advisory/recommendations.sql \
  > "$OUT_DIR/recommendations_${TS}.csv"

echo "✔ Advisory recommendations exported:"
echo "  - $OUT_DIR/recommendations_${TS}.csv"
