#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=threadforge-system
POD=$(kubectl -n "$NAMESPACE" get pods -l app=clickhouse -o jsonpath='{.items[0].metadata.name}')
OUT_DIR=artifacts/drift
TS=$(date -u +"%Y%m%dT%H%M%SZ")

mkdir -p "$OUT_DIR"

kubectl -n "$NAMESPACE" exec "$POD" -- \
  clickhouse-client --format=CSV \
  < scripts/drift/schema_fingerprint.sql \
  > "$OUT_DIR/schema_${TS}.csv"

echo "✔ Drift fingerprint captured: $OUT_DIR/schema_${TS}.csv"