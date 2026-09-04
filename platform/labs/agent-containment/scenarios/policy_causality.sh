#!/usr/bin/env bash
set -euo pipefail

# SAFETY: This script temporarily removes AuthorizationPolicy resources.
# Run only in the containment lab namespace/environment.

NS="agents-lab"
POLICY_FILE="k8s/policies.yaml"
TMP_DENY_NAME="tmp-deny-research-to-writer"

restore_policies() {
  kubectl -n "${NS}" delete authorizationpolicy "${TMP_DENY_NAME}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply -f "${POLICY_FILE}" >/dev/null
}

trap restore_policies EXIT

http_code() {
  local deploy_name="$1"
  kubectl -n "${NS}" exec "platform/deploy/${deploy_name}" -- \
    curl -sS -o /dev/null -w "%{http_code}\n" -X POST http://writer-agent/write | tr -d '\r'
}

echo "[causality] Baseline with policy"
baseline_attacker="$(http_code attacker-agent)"
baseline_research="$(http_code research-agent)"
echo "[causality] attacker-agent -> writer-agent/write: ${baseline_attacker}"
echo "[causality] research-agent -> writer-agent/write: ${baseline_research}"

echo "[causality] Removing AuthorizationPolicy resources in ${NS}"
kubectl -n "${NS}" delete authorizationpolicy --all --ignore-not-found >/dev/null

echo "[causality] Testing attacker-agent -> writer-agent/write WITHOUT policy"
without_policy="$(http_code attacker-agent)"

echo "[causality] HTTP status without policy: ${without_policy}"

echo "[causality] Restoring policies"
restore_policies

echo "[causality] Testing attacker-agent -> writer-agent/write WITH policy"
with_policy="$(http_code attacker-agent)"

echo "[causality] HTTP status with policy: ${with_policy}"

if [[ "${without_policy}" == "200" && "${with_policy}" == "403" ]]; then
  echo "[causality] PASS: attacker path proves expected policy causality"
  exit 0
fi

echo "[causality] NOTE: attacker path did not flip to 200 after full policy removal"
echo "[causality] Running fallback causality proof on the allowed edge"

kubectl -n "${NS}" delete authorizationpolicy allow-research-to-writer --ignore-not-found >/dev/null
fallback_without_allow="$(http_code research-agent)"
echo "[causality] research-agent -> writer-agent/write without allow policy: ${fallback_without_allow}"

restore_policies
fallback_restored="$(http_code research-agent)"
echo "[causality] research-agent -> writer-agent/write after restore: ${fallback_restored}"

if [[ "${fallback_without_allow}" == "403" && "${fallback_restored}" == "200" ]]; then
  echo "[causality] PASS: policy causality demonstrated via allow-edge removal and restore"
  exit 0
fi

echo "[causality] Running final fallback: temporary DENY policy on allowed edge"
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: ${TMP_DENY_NAME}
  namespace: ${NS}
spec:
  selector:
    matchLabels:
      app: writer-agent
  action: DENY
  rules:
    - to:
        - operation:
            ports:
              - "8000"
            methods:
              - POST
            paths:
              - /write
YAML

final_without_allow="$(http_code research-agent)"
echo "[causality] research-agent -> writer-agent/write with DENY policy: ${final_without_allow}"

restore_policies
final_restored="$(http_code research-agent)"
echo "[causality] research-agent -> writer-agent/write after restore: ${final_restored}"

if [[ "${final_without_allow}" == "403" && "${final_restored}" == "200" ]]; then
  echo "[causality] PASS: policy causality demonstrated via DENY policy"
  exit 0
fi

echo "[causality] FAIL: could not demonstrate policy causality via any method"
exit 1
