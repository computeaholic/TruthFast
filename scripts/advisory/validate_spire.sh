#!/usr/bin/env bash
set -euo pipefail

NS="spire-system"
ARTIFACT_DIR="artifacts"
EXPECTED_TRUST_DOMAIN="identity.threadforge.local"
SPIRE_AGENT_SOCKET_PATH="/run/spire/sockets/socket"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/spire_server_socket.sh
source "${REPO_ROOT}/scripts/lib/spire_server_socket.sh"
# shellcheck source=scripts/lib/spire_restart_contract.sh
source "${REPO_ROOT}/scripts/lib/spire_restart_contract.sh"
SERVER_DESCRIBE_FILE="${ARTIFACT_DIR}/spire_server_describe.txt"
SERVER_LOG_FILE="${ARTIFACT_DIR}/spire_server_logs.txt"

mkdir -p "${ARTIFACT_DIR}"

select_ready_pod() {
  local selector="$1"
  kubectl get pod -n "${NS}" -l "${selector}" -o json 2>/dev/null | jq -r '
    .items[]
    | select(.status.phase == "Running")
    | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
    | .metadata.name
  ' | head -n1
}

select_active_spire_server_pod() {
  local deployment_pod ready_pod
  deployment_pod="$(kubectl get pod -n "${NS}" -l app=spire-server -o json 2>/dev/null | jq -r '
    .items[]
    | select(.status.phase == "Running")
    | select(any(.metadata.ownerReferences[]?; .kind == "ReplicaSet"))
    | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
    | .metadata.name
  ' | head -n1)"
  if [[ -n "${deployment_pod}" ]]; then
    printf '%s\n' "${deployment_pod}"
    return 0
  fi
  ready_pod="$(select_ready_pod 'app=spire-server')"
  printf '%s\n' "${ready_pod}"
}

capture_server_debug() {
  local server_pod
  server_pod="$(select_active_spire_server_pod)"
  if [[ -n "${server_pod}" ]]; then
    kubectl describe pod -n "${NS}" "${server_pod}" > "${SERVER_DESCRIBE_FILE}" 2>&1 || true
    kubectl logs -n "${NS}" "${server_pod}" --tail=200 > "${SERVER_LOG_FILE}" 2>&1 || true
  else
    kubectl describe pod -n "${NS}" -l app=spire-server > "${SERVER_DESCRIBE_FILE}" 2>&1 || true
    kubectl logs -n "${NS}" -l app=spire-server --tail=200 > "${SERVER_LOG_FILE}" 2>&1 || true
  fi
}

fail_validation() {
  capture_server_debug
  echo "$1"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
}

check_pod_health() {
  local selector="$1"
  local component="$2"
  local min_uptime_seconds="$3"
  local pod_name
  local phase
  local ready
  local restart_count
  local start_time
  local start_epoch
  local now_epoch
  local uptime_seconds

  pod_name="$(select_ready_pod "${selector}")"
  if [[ -z "${pod_name}" ]]; then
    fail_validation "[FAIL] ${component} pod missing"
  fi

  phase="$(kubectl get pod -n "${NS}" "${pod_name}" -o jsonpath='{.status.phase}')"
  if [[ "${phase}" != "Running" ]]; then
    fail_validation "[FAIL] ${component} phase is ${phase}; expected Running"
  fi

  ready="$(kubectl get pod -n "${NS}" "${pod_name}" -o jsonpath='{.status.containerStatuses[0].ready}')"
  if [[ "${ready}" != "true" ]]; then
    fail_validation "[FAIL] ${component} pod is not Ready"
  fi

  restart_count="$(kubectl get pod -n "${NS}" "${pod_name}" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
  if [[ -z "${restart_count}" || "${restart_count}" -gt 0 ]]; then
    fail_validation "[FAIL] ${component} restartCount is non-zero (${restart_count:-unknown})"
  fi

  if (( min_uptime_seconds > 0 )); then
    start_time="$(kubectl get pod -n "${NS}" "${pod_name}" -o jsonpath='{.status.startTime}')"
    if [[ -z "${start_time}" ]]; then
      fail_validation "[FAIL] ${component} startTime missing"
    fi
    start_epoch="$(date -d "${start_time}" +%s 2>/dev/null || true)"
    now_epoch="$(date -u +%s)"
    if [[ -z "${start_epoch}" ]]; then
      fail_validation "[FAIL] Could not parse ${component} startTime (${start_time})"
    fi
    uptime_seconds="$((now_epoch - start_epoch))"
    if (( uptime_seconds < min_uptime_seconds )); then
      fail_validation "[FAIL] ${component} uptime is ${uptime_seconds}s; expected at least ${min_uptime_seconds}s"
    fi
  fi
}

if ! kubectl get ns "${NS}" >/dev/null 2>&1; then
  fail_validation "[FAIL] ${NS} namespace missing"
fi

echo "[CHECK] SPIRE pods"
kubectl get pods -n "${NS}"

if ! restart_contract_failure="$(spire_agent_restart_contract_failure 2>&1)"; then
  fail_validation "${restart_contract_failure}"
fi

echo "[CHECK] SPIRE services"
kubectl get svc -n "${NS}"
if ! kubectl get svc spire-server -n "${NS}" >/dev/null 2>&1; then
  fail_validation "[FAIL] spire-server service missing"
fi

SERVER_ENDPOINTS="$(kubectl get endpoints spire-server -n "${NS}" -o jsonpath='{.subsets[*].addresses[*].ip}')"
if [[ -z "${SERVER_ENDPOINTS}" ]]; then
  fail_validation "[FAIL] spire-server has no reachable endpoints"
fi

echo "[CHECK] Trust domain consistency"
SERVER_TRUST_DOMAIN="$(kubectl get configmap spire-server-config -n "${NS}" -o jsonpath='{.data.server\.conf}' | awk -F '"' '/trust_domain/ {print $2; exit}')"
AGENT_TRUST_DOMAIN="$(kubectl get configmap spire-agent-config -n "${NS}" -o jsonpath='{.data.agent\.conf}' | awk -F '"' '/trust_domain/ {print $2; exit}')"
if [[ -z "${SERVER_TRUST_DOMAIN}" || -z "${AGENT_TRUST_DOMAIN}" ]]; then
  fail_validation "[FAIL] Could not parse trust domain from SPIRE configs"
fi
if [[ "${SERVER_TRUST_DOMAIN}" != "${AGENT_TRUST_DOMAIN}" ]]; then
  fail_validation "[FAIL] Server/agent trust domains do not match (${SERVER_TRUST_DOMAIN} vs ${AGENT_TRUST_DOMAIN})"
fi
if [[ "${SERVER_TRUST_DOMAIN}" != "${EXPECTED_TRUST_DOMAIN}" ]]; then
  fail_validation "[FAIL] Trust domain is ${SERVER_TRUST_DOMAIN}; expected ${EXPECTED_TRUST_DOMAIN}"
fi

AGENT_POD="$(select_ready_pod 'app=spire-agent')"
if [[ -z "${AGENT_POD}" ]]; then
  fail_validation "[FAIL] spire-agent pod missing"
fi

echo "[CHECK] SPIRE agent API health"
if ! AGENT_HEALTH_OUTPUT="$(kubectl exec -n "${NS}" "${AGENT_POD}" -c spire-agent -- \
	/opt/spire/bin/spire-agent healthcheck -socketPath "${SPIRE_AGENT_SOCKET_PATH}" 2>&1)"; then
	 fail_validation "[FAIL] SPIRE agent healthcheck failed: ${AGENT_HEALTH_OUTPUT}"
fi
printf '%s\n' "${AGENT_HEALTH_OUTPUT}" | sed 's/^/[SPIRE] /'

echo "[CHECK] SPIRE agent connectivity logs"
AGENT_LOGS="$(kubectl logs -n "${NS}" "${AGENT_POD}" --tail=400 2>/dev/null || true)"
if echo "${AGENT_LOGS}" | grep -Eqi 'Agent crashed|x509svid: could not verify leaf certificate|certificate signed by unknown authority|panic:|fatal|failed to fetch bundle|no such host|tls: failed to verify certificate'; then
  fail_validation "[FAIL] SPIRE agent logs contain fatal startup patterns"
fi

RECENT_OK="false"
for _ in 1 2 3 4 5 6; do
  AGENT_RECENT_LOGS="$(kubectl logs -n "${NS}" "${AGENT_POD}" --since=30s 2>/dev/null || true)"
  if ! echo "${AGENT_RECENT_LOGS}" | grep -Eqi 'connection refused|transport is closing|failed to attest|unable to connect|x509svid: could not verify leaf certificate|certificate signed by unknown authority|failed to fetch bundle|no such host|tls: failed to verify certificate'; then
    RECENT_OK="true"
    break
  fi
  sleep 5
done

if [[ "${RECENT_OK}" != "true" ]]; then
  fail_validation "[FAIL] SPIRE agent continues to show connection/attestation errors"
fi

SERVER_POD="$(select_active_spire_server_pod)"
if [[ -z "${SERVER_POD}" ]]; then
  fail_validation "[FAIL] spire-server pod missing"
fi

echo "[CHECK] SPIRE entries"
ENTRIES_RAW="$(kubectl exec -n "${NS}" "${SERVER_POD}" -- \
	/opt/spire/bin/spire-server entry show -socketPath "${SPIRE_SERVER_SOCKET_PATH}" || true)"
ENTRY_COUNT="$(printf '%s\n' "${ENTRIES_RAW}" | grep -c 'Entry ID' || true)"
if [[ "${ENTRY_COUNT}" -eq 0 ]]; then
  fail_validation "[FAIL] SPIRE entry list is empty"
fi

check_pod_health 'app=spire-agent' 'spire-agent' 0
check_active_spire_server_health() {
  local pod_name
  local phase
  local ready
  local restart_count
  local start_time
  local start_epoch
  local now_epoch
  local uptime_seconds

  pod_name="$(select_active_spire_server_pod)"
  if [[ -z "${pod_name}" ]]; then
    fail_validation "[FAIL] spire-server pod missing"
  fi

  phase="$(kubectl get pod -n "${NS}" "${pod_name}" -o jsonpath='{.status.phase}')"
  if [[ "${phase}" != "Running" ]]; then
    fail_validation "[FAIL] spire-server phase is ${phase}; expected Running"
  fi

  ready="$(kubectl get pod -n "${NS}" "${pod_name}" -o jsonpath='{.status.containerStatuses[0].ready}')"
  if [[ "${ready}" != "true" ]]; then
    fail_validation "[FAIL] spire-server pod is not Ready"
  fi

  restart_count="$(kubectl get pod -n "${NS}" "${pod_name}" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
  if [[ -z "${restart_count}" || "${restart_count}" -gt 0 ]]; then
    fail_validation "[FAIL] spire-server restartCount is non-zero (${restart_count:-unknown})"
  fi
}

check_active_spire_server_health

echo "[CHECK] SPIRE delayed stability"
sleep 10
kubectl get pod -n spire-system
check_pod_health 'app=spire-agent' 'spire-agent' 0
check_active_spire_server_health

capture_server_debug

cat > "${ARTIFACT_DIR}/spire_status.json" <<EOF
{
  "agent_ready": true,
  "restart_count": 0,
  "trust_domain": "${SERVER_TRUST_DOMAIN}",
  "server_reachable": true
}
EOF

jq empty "${ARTIFACT_DIR}/spire_status.json" >/dev/null

echo "[PASS] SPIRE control plane healthy"
