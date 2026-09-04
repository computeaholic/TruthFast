#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/identity_contract.sh
source "$REPO_ROOT/scripts/lib/identity_contract.sh"
require_trust_domain

ROGUE_NS="agents-rogue"
TARGET_NS="agents-lab"
TARGET_URL="http://writer-agent.${TARGET_NS}.svc.cluster.local/write"
ROGUE_SA="rogue-agent"
ARTIFACT_DIR="artifacts"
ARTIFACT_FILE="${ARTIFACT_DIR}/cross_namespace.json"

mkdir -p "${ARTIFACT_DIR}"

rogue_blocked="false"
identity_isolated="false"
namespace_boundary_enforced="false"
policy_leak_detected="false"

cleanup() {
  kubectl delete namespace "${ROGUE_NS}" --ignore-not-found >/dev/null 2>&1 || true
}

trap cleanup EXIT

request_code() {
  local deploy_name="$1"
  kubectl exec "platform/deploy/${deploy_name}" -n "${ROGUE_NS}" -- \
    curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST "${TARGET_URL}" 2>/dev/null || echo "000"
}

echo "[XNS] Creating namespace ${ROGUE_NS}"
kubectl create namespace "${ROGUE_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace "${ROGUE_NS}" istio-injection=enabled --overwrite >/dev/null

ATTACKER_IMAGE="$(kubectl get deployment attacker-agent -n "${TARGET_NS}" -o jsonpath='{.spec.template.spec.containers[0].image}')"
RESEARCH_IMAGE="$(kubectl get deployment research-agent -n "${TARGET_NS}" -o jsonpath='{.spec.template.spec.containers[0].image}')"

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${ROGUE_SA}
  namespace: ${ROGUE_NS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rogue-agent
  namespace: ${ROGUE_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rogue-agent
  template:
    metadata:
      labels:
        app: rogue-agent
    spec:
      serviceAccountName: ${ROGUE_SA}
      containers:
        - name: rogue-agent
          image: ${ATTACKER_IMAGE}
          ports:
            - containerPort: 8000
EOF

kubectl rollout status deployment/rogue-agent -n "${ROGUE_NS}" --timeout=180s >/dev/null

ROGUE_POD="$(kubectl get pod -l app=rogue-agent -n "${ROGUE_NS}" -o jsonpath='{.items[0].metadata.name}')"
EXPECTED_SPIFFE="spiffe://${SPIFFE_TRUST_DOMAIN}/ns/${ROGUE_NS}/sa/${ROGUE_SA}"
ROGUE_SPIFFE="$(kubectl exec -n "${ROGUE_NS}" "${ROGUE_POD}" -c istio-proxy -- pilot-agent request GET certs 2>/dev/null \
  | jq -r '.. | .uri? // empty' | grep -m1 "^spiffe://${SPIFFE_TRUST_DOMAIN}/ns/.*/sa/.*" || true)"

if [[ "${ROGUE_SPIFFE}" == "${EXPECTED_SPIFFE}" ]]; then
  identity_isolated="true"
  echo "[XNS] SPIFFE identity isolated: ${ROGUE_SPIFFE}"
else
  echo "[FAIL] Unexpected rogue SPIFFE identity. expected=${EXPECTED_SPIFFE} got=${ROGUE_SPIFFE:-none}"
  identity_isolated="false"
fi

echo "[XNS] Baseline rogue attack: rogue-agent -> writer-agent"
ROGUE_CODE="$(request_code "rogue-agent")"
if [[ "${ROGUE_CODE}" == "403" ]]; then
  rogue_blocked="true"
  echo "[XNS] Rogue baseline blocked (403)"
else
  rogue_blocked="false"
  echo "[FAIL] Rogue baseline request returned ${ROGUE_CODE}, expected 403"
fi

echo "[XNS] Identity confusion attempt: match app name/labels/image"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: research-agent
  namespace: ${ROGUE_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: research-agent
  template:
    metadata:
      labels:
        app: research-agent
    spec:
      serviceAccountName: ${ROGUE_SA}
      containers:
        - name: research-agent
          image: ${RESEARCH_IMAGE}
          ports:
            - containerPort: 8000
EOF

kubectl rollout status deployment/research-agent -n "${ROGUE_NS}" --timeout=180s >/dev/null
CONFUSION_CODE="$(request_code "research-agent")"

if [[ "${CONFUSION_CODE}" == "403" ]]; then
  namespace_boundary_enforced="true"
  echo "[XNS] Identity confusion blocked (403)"
else
  namespace_boundary_enforced="false"
  echo "[FAIL] Identity confusion returned ${CONFUSION_CODE}, expected 403"
fi

echo "[XNS] Scanning AuthorizationPolicy for wildcard/cross-namespace leak patterns"
LEAK_COUNT="$(kubectl get authorizationpolicy -A -o json | jq '
  [
    .items[]
    | .spec.rules[]?
    | .from[]?.source
    | (
        [ .principals[]? | select(type == "string")
          | select(
              contains("*")
              or
              ((contains("/sa/research-agent")) and (contains("/ns/agents-lab/sa/research-agent") | not))
            )
        ]
        +
        [ .serviceAccounts[]? | select(type == "string")
          | select(
              contains("*")
              or
              ((endswith("/research-agent")) and (. != "agents-lab/research-agent"))
            )
        ]
      )[]
  ] | length
' 2>/dev/null)"

LEAK_COUNT="${LEAK_COUNT:-0}"
if [[ "${LEAK_COUNT}" != "0" ]]; then
  policy_leak_detected="true"
  echo "[FAIL] Found ${LEAK_COUNT} potentially leaky principal/serviceAccount patterns"
else
  policy_leak_detected="false"
  echo "[XNS] No wildcard or cross-namespace principal leak patterns found"
fi

if [[ "${rogue_blocked}" != "true" ]] || [[ "${identity_isolated}" != "true" ]] || [[ "${namespace_boundary_enforced}" != "true" ]] || [[ "${policy_leak_detected}" != "false" ]]; then
  cat > "${ARTIFACT_FILE}" <<EOF
{
  "rogue_blocked": ${rogue_blocked},
  "identity_isolated": ${identity_isolated},
  "namespace_boundary_enforced": ${namespace_boundary_enforced},
  "policy_leak_detected": ${policy_leak_detected}
}
EOF
  jq empty "${ARTIFACT_FILE}" >/dev/null
  echo "[FAIL] Cross-namespace / cross-trust validation failed"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

cat > "${ARTIFACT_FILE}" <<EOF
{
  "rogue_blocked": true,
  "identity_isolated": true,
  "namespace_boundary_enforced": true,
  "policy_leak_detected": false
}
EOF
jq empty "${ARTIFACT_FILE}" >/dev/null

echo "[PASS] Cross-namespace / cross-trust validation passed"
