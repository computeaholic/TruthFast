#!/usr/bin/env bash
set -euo pipefail

NS="threadforge-system"
PROBE_IMG="registry.threadforge.local:30500/mirror/docker.io/curlimages/curl@sha256:4a3396ae573c44932d06ba33f8696db4429c419da87cbdc82965ee96a37dd0af"

echo "[check_data] verifying services exist"
kubectl -n "$NS" get svc clickhouse
kubectl -n "$NS" get svc minio

echo "[check_data] ClickHouse query: SELECT 1"
kubectl -n "$NS" run ch-probe --rm -i --restart=Never --image="$PROBE_IMG" --command -- sh -c "curl -fsS 'http://clickhouse:8123/?query=SELECT%201' | grep -qx '1'"

echo "[check_data] MinIO health endpoint"
kubectl -n "$NS" run minio-probe --rm -i --restart=Never --image="$PROBE_IMG" --command -- sh -c "curl -fsS http://minio:9000/minio/health/live >/dev/null"

if kubectl -n "$NS" get svc postgres >/dev/null 2>&1; then
  echo "[check_data] Postgres simple query"
  kubectl -n "$NS" run pg-probe --rm -i --restart=Never --image="registry.threadforge.local:30500/postgres@sha256:d1729fc63e9c7b6c5d17e153297c176fef495568bf7528032b78e60e5ad6f2dd" --env PGPASSWORD=threadforge123 --command -- sh -c "psql -h postgres -U threadforge -d threadforge -c 'SELECT 1'"
fi

echo "[check_data] PASS"
