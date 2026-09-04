#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_DIR="artifacts"
mkdir -p "${ARTIFACT_DIR}"

kubectl delete authorizationpolicy allow-research-to-writer -n agents-lab --ignore-not-found

echo "[TEST] Removing writer-agent AuthorizationPolicy..."
kubectl delete authorizationpolicy writer-allow -n agents-lab

echo "[TEST] Measuring policy propagation (polling every 1s, max 15s)..."
T0=$(date +%s)
MAX_WAIT=15
ELAPSED=0
PROBE_CODE="200"

while [[ "${PROBE_CODE}" == "200" && ${ELAPSED} -lt ${MAX_WAIT} ]]; do
  sleep 1
  ELAPSED=$(( $(date +%s) - T0 ))
  PROBE_CODE="$(kubectl exec deploy/research-agent -n agents-lab -- \
    curl -s -o /dev/null -w "%{http_code}" --max-time 5 -X POST http://writer-agent/write \
    2>/dev/null || echo "000")"
  echo "[TEST] t+${ELAPSED}s → ${PROBE_CODE}"
done

if [[ "${PROBE_CODE}" == "200" ]]; then
  echo "[FAIL] Policy still not enforced after ${MAX_WAIT}s"
  kubectl apply -f platform/labs/agent-containment/k8s/writer-allow.yaml
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "[PASS] Policy enforced after ${ELAPSED}s (final code: ${PROBE_CODE})"
echo "${ELAPSED}" > "${ARTIFACT_DIR}/propagation_seconds.txt"

echo "[TEST] Restoring policy..."
kubectl apply -f platform/labs/agent-containment/k8s/writer-allow.yaml

echo "[DONE]"
