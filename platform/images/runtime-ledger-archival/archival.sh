#!/bin/sh
set -e

mc alias set local "$MINIO_URL" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"

for f in /var/threadforge/logs/operator/ledger/*.jsonl; do
  [ -e "$f" ] || continue
  mc cp "$f" local/"$MINIO_BUCKET"/
done

echo "[archival] Completed"
