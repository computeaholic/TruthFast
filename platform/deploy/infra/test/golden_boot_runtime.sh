#!/usr/bin/env bash
# requires_identity=true  # trust_tier=full
if ! bash platform/runtime/operator/identity_enforcer.sh --require-full >/dev/null 2>&1; then
  echo "[FAIL] identity enforcement requires a full trust tier" >&2
  exit 2
fi

set -e

kubectl delete pod -n tempo tempo-0
kubectl wait --for=condition=Ready pod -n tempo -l app=tempo --timeout=120s
kubectl logs -n tempo tempo-0 | grep -q "Starting Tempo"

echo "✓ Golden Boot runtime verified"
