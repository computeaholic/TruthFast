#!/usr/bin/env bash
set -euo pipefail

NS="agents-lab"

# This pod opts out of sidecar injection so it does not receive a mesh-issued SPIFFE identity.
# Without a trusted workload identity, the request cannot satisfy mesh authorization and is rejected.
echo "[identity-spoof] Launching an ad hoc curl pod outside the lab workload set"
echo "[identity-spoof] SPIFFE identity and mesh mTLS are required; unknown workloads should be denied"

kubectl -n "${NS}" run spoof-test \
  --rm -i \
  --restart=Never \
  --image=curlimages/curl \
  --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' \
  --command -- \
  curl -sS -o /dev/null -w "%{http_code}\n" http://writer-agent
