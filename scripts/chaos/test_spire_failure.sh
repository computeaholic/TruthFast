#!/usr/bin/env bash
set -euo pipefail

NS="agents-lab"
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
ARTIFACT_DIR="artifacts"

mkdir -p "${ARTIFACT_DIR}"

if ! kubectl get ns spire-system >/dev/null 2>&1; then
  echo "[FAIL] spire-system namespace missing"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if ! kubectl get deploy spire-server -n spire-system >/dev/null 2>&1; then
  echo "[FAIL] spire-server deployment missing"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "[SPIRE-FAILURE] timestamp=${TS}"
echo "[SPIRE-FAILURE] Scaling spire-server to 0"
kubectl scale deployment spire-server -n spire-system --replicas=0

echo "[SPIRE-FAILURE] Waiting 45s"
for _ in 1 2 3; do
  sleep 15
  echo "[SPIRE-FAILURE] wait_progress=15s"
done

echo "[SPIRE-FAILURE] Request result from research-agent to writer-agent"
SPIRE_FAILURE_CODE="$(kubectl exec deploy/research-agent -n "${NS}" -- \
  curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST http://writer-agent/write)"

echo "[SPIRE-FAILURE] request_result=${SPIRE_FAILURE_CODE}"
IDENTITY_STILL_WORKS="false"
if [[ "${SPIRE_FAILURE_CODE}" == "200" ]]; then
  IDENTITY_STILL_WORKS="true"
  echo "[SPIRE-FAILURE] identity_still_valid=true"
else
  echo "[SPIRE-FAILURE] identity_still_valid=false"
fi

echo "[SPIRE-FAILURE] Restoring spire-server"
kubectl scale deployment spire-server -n spire-system --replicas=1
kubectl rollout status deployment/spire-server -n spire-system --timeout=180s

cat > "${ARTIFACT_DIR}/chaos_spire.json" <<EOF
{
  "timestamp": "${TS}",
  "spire_down": true,
  "request_result": ${SPIRE_FAILURE_CODE},
  "identity_still_valid": ${IDENTITY_STILL_WORKS}
}
EOF

jq empty "${ARTIFACT_DIR}/chaos_spire.json" >/dev/null

echo "[SPIRE-FAILURE] complete"
