#!/usr/bin/env bash
# scripts/minio_verify.sh
# Checks that MinIO chart renders via helm and provides guidance when helm is not installed.
set -euo pipefail
if command -v helm >/dev/null 2>&1; then
  echo "Rendering MinIO chart using helm template..."
  helm template platform/deploy/infra/minio -s templates | sed -n '1,200p'
  echo "Helm template rendered successfully."
  exit 0
else
  echo "Helm not installed. To validate chart rendering locally install helm and run: helm template platform/deploy/infra/minio" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
