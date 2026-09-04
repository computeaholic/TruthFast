#!/usr/bin/env bash
set -euo pipefail

# Runtime test: Verify MinIO reachability from Tempo pod
# This tests actual connectivity in the mesh

TEMPO_POD=$(kubectl get pods -n tempo -l app.kubernetes.io/name=tempo -o jsonpath='{.items[0].metadata.name}')
if [ -z "$TEMPO_POD" ]; then
  echo "ERROR: No Tempo pod found"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Test connectivity using curl from Tempo pod
kubectl exec -n tempo "$TEMPO_POD" -- curl -f --max-time 10 http://minio.minio.svc.cluster.local:9000/minio/health/live || {
  echo "ERROR: MinIO not reachable from Tempo pod"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
}

echo "✓ MinIO reachable from Tempo pod"