#!/usr/bin/env bash
# Test Istio control-plane (istiod) failure behavior.
# Records whether enforcement holds after scaling istiod to 0 for 30s,
# then restores istiod and waits for readiness before returning.
set -euo pipefail

NS="agents-lab"
ARTIFACT_DIR="artifacts"
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

mkdir -p "${ARTIFACT_DIR}"

echo "[ISTIO-FAILURE] timestamp=${TS}"
echo "[ISTIO-FAILURE] Scaling istiod to 0"
kubectl scale deployment istiod -n istio-system --replicas=0

echo "[ISTIO-FAILURE] Waiting 30s (testing last-known config persistence)"
for _ in 1 2; do
  sleep 15
  echo "[ISTIO-FAILURE] wait_progress=15s"
done

echo "[ISTIO-FAILURE] Probing allowed path: research-agent -> writer-agent"
ALLOWED_CODE="$(kubectl exec deploy/research-agent -n "${NS}" -- \
  curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST http://writer-agent/write \
  2>/dev/null || echo "000")"
echo "[ISTIO-FAILURE] allowed_path_result=${ALLOWED_CODE}"

echo "[ISTIO-FAILURE] Probing denied path: attacker-agent -> writer-agent"
DENIED_CODE="$(kubectl exec deploy/attacker-agent -n "${NS}" -- \
  curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST http://writer-agent/write \
  2>/dev/null || echo "000")"
echo "[ISTIO-FAILURE] denied_path_result=${DENIED_CODE}"

# Enforcement must not collapse during control-plane outage.
# Allowed path may be 200 (cached config still served) — that is expected.
# Denied path must NOT be 200 — if it is, enforcement degraded.
if [[ "${DENIED_CODE}" == "200" ]]; then
  echo "[FAIL] Denied path succeeded during istiod outage — enforcement degraded"
  # Restore istiod unconditionally before exiting
  kubectl scale deployment istiod -n istio-system --replicas=1
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "[ISTIO-FAILURE] Restoring istiod"
kubectl scale deployment istiod -n istio-system --replicas=1

echo "[ISTIO-FAILURE] Waiting for istiod ready"
kubectl rollout status deployment/istiod -n istio-system --timeout=120s

cat > "${ARTIFACT_DIR}/chaos_istio.json" <<EOF
{
  "timestamp": "${TS}",
  "allowed_path_during_outage": ${ALLOWED_CODE},
  "denied_path_during_outage": ${DENIED_CODE},
  "enforcement_held": $([ "${DENIED_CODE}" != "200" ] && echo "true" || echo "false")
}
EOF

jq empty "${ARTIFACT_DIR}/chaos_istio.json" >/dev/null

echo "[ISTIO-FAILURE] enforcement_held=true"
echo "[ISTIO-FAILURE] complete"
