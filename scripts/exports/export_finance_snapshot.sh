#!/usr/bin/env bash
set -euo pipefail

NS=threadforge-system
POD=$(kubectl -n "$NS" get pods -l app=clickhouse -o jsonpath='{.items[0].metadata.name}')
OUT=artifacts/exports
TS=$(date -u +"%Y%m%dT%H%M%SZ")

mkdir -p "$OUT"

kubectl -n "$NS" exec "$POD" -- \
  clickhouse-client --format=CSV \
  < data/queries/governance/review_packet.sql \
  > "$OUT/finance_snapshot_${TS}.csv"

kubectl -n "$NS" exec "$POD" -- \
  clickhouse-client --format=CSV \
  < data/queries/presentation/cost_in_currency.sql \
  > "$OUT/finance_currency_${TS}.csv"

echo "✔ Finance exports written to $OUT"