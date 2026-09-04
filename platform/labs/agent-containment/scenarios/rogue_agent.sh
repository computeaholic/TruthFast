#!/usr/bin/env bash
set -euo pipefail

NS="agents-lab"
ROGUE_DEPLOY="rogue-agent"

# rogue-agent has its own SPIFFE identity but receives no AuthorizationPolicy grants.
# Both probes should be rejected with 403 by the destination workloads' RBAC rules.
echo "[rogue-agent] Probing protected services from an unauthorized workload identity"
echo "[rogue-agent] No AuthorizationPolicy grants ${ROGUE_DEPLOY} access to research-agent or writer-agent"

failed=0
for host in research-agent writer-agent; do
  echo "[rogue-agent] GET http://${host}/healthz"
  code="$(kubectl -n "${NS}" exec deploy/"${ROGUE_DEPLOY}" -- \
    curl -sS -o /dev/null -w "%{http_code}\n" "http://${host}/healthz" | tr -d '\r')"
  echo "[rogue-agent] HTTP status from ${host}: ${code}"
  if [[ "${code}" != "403" ]]; then
    echo "[rogue-agent] FAIL: expected 403 from ${host} but got ${code}"
    failed=1
  fi
done

if [[ "${failed}" -ne 0 ]]; then
  echo "[rogue-agent] FAIL: rogue-agent reached a protected service"
  exit 1
fi

echo "[rogue-agent] PASS: rogue-agent denied from all protected services"
