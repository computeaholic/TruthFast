#!/usr/bin/env bash
set -euo pipefail

# Registry health check (observe-only)
# - Uses $REGISTRY_URL if set; otherwise probes the canonical TLS registry endpoint
# - Verifies connectivity from inside the kind node where containerd trust is authoritative
# - Exits non-zero if no reachable registry endpoint found

CLUSTER_NAME="${CLUSTER_NAME:-threadforge}"

resolve_kind_node() {
  kind get nodes --name "$CLUSTER_NAME" 2>/dev/null | head -n 1
}

REGISTRY_URLS=()
if [ -n "${REGISTRY_URL-}" ]; then
  REGISTRY_URLS+=("${REGISTRY_URL}")
fi
REGISTRY_URLS+=("https://registry.threadforge.local:30500")
KIND_NODE="$(resolve_kind_node)"
if [ -z "$KIND_NODE" ]; then
  echo "[registry_health] ERROR: no kind node found for cluster ${CLUSTER_NAME}" >&2
  exit 10
fi

echo "[registry_health] Checking registry reachability..."
OK=0
for u in "${REGISTRY_URLS[@]}"; do
  # Check the Docker Registry v2 endpoint
  url="$u/v2/"
  status=$(docker exec "$KIND_NODE" sh -c "curl --silent --max-time 5 --write-out '%{http_code}' --output /dev/null '$url'" || echo "000")
  # Consider any 2xx–4xx response as "reachable" (registry responded). Treat 5xx or no response as failure.
  if [ "$status" != "000" ] && [ "$status" -ge 200 ] && [ "$status" -lt 500 ]; then
    echo "[registry_health] OK: $u (HTTP $status)"
    OK=1
    break
  else
    echo "[registry_health] no response from $u (HTTP $status)"
  fi
done

if [ "$OK" -ne 1 ]; then
  echo "[registry_health] ERROR: no reachable registry endpoints detected." >&2
  exit 10
fi

echo "[registry_health] Summary: registry reachable."
exit 0
