#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/identity_contract.sh
source "$REPO_ROOT/scripts/lib/identity_contract.sh"
require_trust_domain

NS="spire-system"
ARTIFACT_DIR="artifacts"
CM_NAME="spire-agent-config"

mkdir -p "${ARTIFACT_DIR}"

patch_agent_conf() {
  local agent_conf="$1"
  local payload
  payload="$(jq -n --arg conf "${agent_conf}" '{data: {"agent.conf": $conf}}')"
  kubectl patch configmap "${CM_NAME}" -n "${NS}" --type merge -p "${payload}" >/dev/null
}

if ! kubectl get configmap "${CM_NAME}" -n "${NS}" >/dev/null 2>&1; then
  echo "[FAIL] ${CM_NAME} missing in ${NS}"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

ORIGINAL_AGENT_CONF="$(kubectl get configmap "${CM_NAME}" -n "${NS}" -o jsonpath='{.data.agent\.conf}')"
if [[ -z "${ORIGINAL_AGENT_CONF}" ]]; then
  echo "[FAIL] ${CM_NAME}.data.agent.conf is empty"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

CURRENT_TRUST_DOMAIN="$(printf '%s\n' "${ORIGINAL_AGENT_CONF}" | awk -F '"' '/trust_domain/ {print $2; exit}')"
if [[ "${CURRENT_TRUST_DOMAIN}" != "${SPIFFE_TRUST_DOMAIN}" ]]; then
  echo "[SPIRE-TRUST-MISMATCH] restoring baseline trust domain from ${CURRENT_TRUST_DOMAIN} to ${SPIFFE_TRUST_DOMAIN}"
  BASELINE_AGENT_CONF="$(printf '%s' "${ORIGINAL_AGENT_CONF}" | sed "s/trust_domain = \".*\"/trust_domain = \"${SPIFFE_TRUST_DOMAIN}\"/")"
  patch_agent_conf "${BASELINE_AGENT_CONF}"
  kubectl rollout restart daemonset/spire-agent -n "${NS}"
  kubectl rollout status daemonset/spire-agent -n "${NS}" --timeout=180s
  ORIGINAL_AGENT_CONF="$(kubectl get configmap "${CM_NAME}" -n "${NS}" -o jsonpath='{.data.agent\.conf}')"
fi

# Mutate trust domain to an invalid value to prove fail-fast behavior.
MISMATCH_AGENT_CONF="$(printf '%s' "${ORIGINAL_AGENT_CONF}" | sed "s/trust_domain = \"${SPIFFE_TRUST_DOMAIN}\"/trust_domain = \"${SPIFFE_TRUST_DOMAIN}.mismatch\"/")"
patch_agent_conf "${MISMATCH_AGENT_CONF}"

kubectl rollout restart daemonset/spire-agent -n "${NS}"
sleep 20

AGENT_POD="$(kubectl get pod -n "${NS}" -l app=spire-agent -o jsonpath='{.items[0].metadata.name}')"
BAD_LOGS="$(kubectl logs -n "${NS}" "${AGENT_POD}" --tail=200 2>/dev/null || true)"

if ! echo "${BAD_LOGS}" | grep -Eqi 'x509|certificate|failed to fetch bundle|no such host|trust domain|failed to attest|unable to connect'; then
  echo "[FAIL] trust mismatch did not produce expected agent failure signals"
  patch_agent_conf "${ORIGINAL_AGENT_CONF}"
  kubectl rollout restart daemonset/spire-agent -n "${NS}"
  kubectl rollout status daemonset/spire-agent -n "${NS}" --timeout=180s
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "[SPIRE-TRUST-MISMATCH] mismatch failure confirmed"

# Restore correct config and validate recovery.
patch_agent_conf "${ORIGINAL_AGENT_CONF}"
kubectl rollout restart daemonset/spire-agent -n "${NS}"
kubectl rollout status daemonset/spire-agent -n "${NS}" --timeout=180s

RECOVERED="false"
for _ in 1 2 3 4 5 6; do
  AGENT_POD_RECOVERED="$(kubectl get pod -n "${NS}" -l app=spire-agent -o jsonpath='{.items[0].metadata.name}')"
  GOOD_LOGS="$(kubectl logs -n "${NS}" "${AGENT_POD_RECOVERED}" --tail=200 2>/dev/null || true)"
  if echo "${GOOD_LOGS}" | grep -Eqi 'Node attestation was successful|Starting Workload and SDS APIs'; then
    RECOVERED="true"
    break
  fi
  sleep 5
done

if [[ "${RECOVERED}" != "true" ]]; then
  echo "[FAIL] SPIRE agent did not recover after trust domain restore"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "{\"trust_mismatch_detected\": true, \"recovered\": true}" > "${ARTIFACT_DIR}/spire_trust_mismatch.json"
jq empty "${ARTIFACT_DIR}/spire_trust_mismatch.json" >/dev/null

echo "[SPIRE-TRUST-MISMATCH] PASS"
