#!/usr/bin/env bash
set -euo pipefail

NS="agents-lab"
ATTACKER_DEPLOY="attacker-agent"

echo "[scan] Attacker deployment: ${ATTACKER_DEPLOY}"
echo "[scan] Probing in-namespace services"

for host in research-agent writer-agent attacker-agent; do
  echo "[scan] GET http://${host}/healthz"
  kubectl -n "${NS}" exec deploy/"${ATTACKER_DEPLOY}" -- \
    sh -c "curl -sS -m 3 -o /dev/null -w '%{http_code}\n' http://${host}/healthz || true"
done
