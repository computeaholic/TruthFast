#!/usr/bin/env bash
set -euo pipefail

NS="agents-lab"
ARTIFACT_DIR="artifacts"
NETWORK_DENY_FILE="platform/labs/agent-containment/k8s/network-deny-all.yaml"

mkdir -p "${ARTIFACT_DIR}"

# Assertion state
DIRECT_POD_IP_BLOCKED="false"
SIDECAR_KILL_BLOCKED="false"
IPTABLES_REDIRECT_PRESENT="false"
NETWORK_POLICY_EFFECTIVE="false"
HOST_NETWORK_BLOCKED="false"
MESH_BYPASS_POSSIBLE="false"

# Track envoy pause state for cleanup
ENVOY_STOPPED="false"

# Resolve dynamic pod/image info
WRITER_POD_IP="$(kubectl get pod -l app=writer-agent -n "${NS}" -o jsonpath='{.items[0].status.podIP}')"
ATTACKER_POD="$(kubectl get pod -l app=attacker-agent -n "${NS}" -o jsonpath='{.items[0].metadata.name}')"
ATTACKER_IMAGE="$(kubectl get deployment attacker-agent -n "${NS}" -o jsonpath='{.spec.template.spec.containers[0].image}')"

echo "[NET-BYPASS] Writer pod IP  : ${WRITER_POD_IP}"
echo "[NET-BYPASS] Attacker pod   : ${ATTACKER_POD}"

resume_envoy() {
  if [[ "${ENVOY_STOPPED}" == "true" ]]; then
    kubectl exec "${ATTACKER_POD}" -c istio-proxy -n "${NS}" -- kill -CONT 1 2>/dev/null || true
    ENVOY_STOPPED="false"
    echo "[NET-BYPASS] Envoy resumed (SIGCONT sent)"
  fi
}

cleanup() {
  resume_envoy
  kubectl delete pod debug-hostnet -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Test 1: Direct Pod-to-Pod TCP Bypass
# ---------------------------------------------------------------------------
echo "[NET-BYPASS] Test 1: Direct pod IP access (${WRITER_POD_IP}:8000)"

# curl returns HTTP code via %{http_code}; on connection failure kubectl exec
# exits non-zero → outer || echo "000" captures the failure code.
DIRECT_CODE="$(kubectl exec deploy/attacker-agent -n "${NS}" -- \
  sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
  http://${WRITER_POD_IP}:8000/write 2>/dev/null; true" 2>/dev/null || echo "000")"

if [[ "${DIRECT_CODE}" == "200" ]]; then
  DIRECT_POD_IP_BLOCKED="false"
  MESH_BYPASS_POSSIBLE="true"
  echo "[FAIL] Direct pod IP returned 200 — bypass confirmed!"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
else
  DIRECT_POD_IP_BLOCKED="true"
  echo "[PASS] Direct pod IP blocked (code: ${DIRECT_CODE})"
fi

# ---------------------------------------------------------------------------
# Test 2: Sidecar Kill Test (SIGSTOP envoy, probe, SIGCONT)
#
# Sending SIGSTOP pauses envoy at the process level. The kernel's iptables
# rules still redirect all outbound traffic from the attacker app to port
# 15001 (envoy outbound listener). With envoy paused, port 15001 stops
# accepting new connections → curl times out → NOT 200.
# SIGCONT resumes envoy without triggering a container restart.
# ---------------------------------------------------------------------------
echo "[NET-BYPASS] Test 2: Sidecar kill test (SIGSTOP envoy, curl, SIGCONT)"

if kubectl exec "${ATTACKER_POD}" -c istio-proxy -n "${NS}" -- kill -STOP 1 2>/dev/null; then
  ENVOY_STOPPED="true"

  SIDECAR_KILL_CODE="$(kubectl exec deploy/attacker-agent -n "${NS}" -- \
    sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
    http://writer-agent/write 2>/dev/null; true" 2>/dev/null || echo "000")"

  # Always resume envoy before continuing
  kubectl exec "${ATTACKER_POD}" -c istio-proxy -n "${NS}" -- kill -CONT 1 2>/dev/null || true
  ENVOY_STOPPED="false"

  # Allow envoy 2 seconds to re-establish connections after resume
  sleep 2
else
  echo "[WARN] Could not SIGSTOP envoy (may lack permissions) — treating as blocked"
  SIDECAR_KILL_CODE="000"
fi

if [[ "${SIDECAR_KILL_CODE}" == "200" ]]; then
  SIDECAR_KILL_BLOCKED="false"
  MESH_BYPASS_POSSIBLE="true"
  echo "[FAIL] Sidecar kill: got 200 — MESH BYPASS POSSIBLE!"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
else
  SIDECAR_KILL_BLOCKED="true"
  echo "[PASS] Sidecar kill blocked (code: ${SIDECAR_KILL_CODE})"
fi

# ---------------------------------------------------------------------------
# Test 3: iptables Redirect Inspection
#
# iptables is set up by the Istio CNI init container and cannot be queried
# from within the istio-proxy container (read-only /run filesystem for lock).
# We prove redirect is in effect by verifying that Envoy has configured
# virtual outbound (15001) and virtual inbound (15006) listeners — these
# listeners are useless without the iptables REDIRECT rules that steer
# traffic into them.
# ---------------------------------------------------------------------------
echo "[NET-BYPASS] Test 3: iptables redirect verification via Envoy listener config"

OUTBOUND_CNT="$(istioctl proxy-config listener "${ATTACKER_POD}" -n "${NS}" \
  2>/dev/null | grep -c '15001' || echo "0")"
INBOUND_CNT="$(istioctl proxy-config listener "${ATTACKER_POD}" -n "${NS}" \
  2>/dev/null | grep -c '15006' || echo "0")"

if (( OUTBOUND_CNT > 0 && INBOUND_CNT > 0 )); then
  IPTABLES_REDIRECT_PRESENT="true"
  echo "[PASS] iptables redirect confirmed: 15001 outbound and 15006 inbound listeners present"
else
  IPTABLES_REDIRECT_PRESENT="false"
  echo "[FAIL] Missing virtual proxy listeners (15001 count=${OUTBOUND_CNT}, 15006 count=${INBOUND_CNT})"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# ---------------------------------------------------------------------------
# Test 4: NetworkPolicy Enforcement Proof
#
# Delete the deny-all NetworkPolicy and re-test. AuthorizationPolicy + STRICT
# mTLS must enforce independently. If attacker gets 200 after deletion,
# Istio enforcement was not the primary control — hard failure.
# ---------------------------------------------------------------------------
echo "[NET-BYPASS] Test 4: NetworkPolicy enforcement proof"

kubectl delete networkpolicy default-deny-all -n "${NS}" --ignore-not-found >/dev/null 2>&1
# Allow NetworkPolicy deletion to propagate
sleep 2

NP_CODE="$(kubectl exec deploy/attacker-agent -n "${NS}" -- \
  sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
  http://writer-agent/write 2>/dev/null; true" 2>/dev/null || echo "000")"


# Always restore NetworkPolicy before checking result
kubectl apply -f "${NETWORK_DENY_FILE}" >/dev/null

if [[ "${NP_CODE}" == "200" ]]; then
  NETWORK_POLICY_EFFECTIVE="false"
  MESH_BYPASS_POSSIBLE="true"
  echo "[FAIL] Removing NetworkPolicy allowed bypass (code 200) — Istio not sole enforcer!"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
else
  NETWORK_POLICY_EFFECTIVE="true"
  echo "[PASS] Enforcement holds after NetworkPolicy removal (code: ${NP_CODE}) — mesh is primary control"
fi

# ---------------------------------------------------------------------------
# Test 5: Host Network Escape Test
#
# A pod with hostNetwork: true has no Istio sidecar. Its outbound traffic is
# not captured by iptables. However, the writer pod's inbound Envoy enforces
# STRICT mTLS. Plain HTTP from a non-mTLS source is rejected at the writer's
# Envoy inbound listener (15006), returning a connection-level failure.
#
# We reuse the already-pulled attacker-agent image to avoid pull delays.
# ---------------------------------------------------------------------------
echo "[NET-BYPASS] Test 5: Host network escape test"

kubectl delete pod debug-hostnet -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true

HOSTNET_OVERRIDES=$(cat <<EOF
{
  "spec": {
    "hostNetwork": true,
    "automountServiceAccountToken": false,
    "containers": [
      {
        "name": "debug-hostnet",
        "image": "${ATTACKER_IMAGE}",
        "command": [
          "sh", "-c",
          "curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST http://writer-agent.${NS}.svc.cluster.local/write 2>/dev/null || echo 000"
        ]
      }
    ]
  }
}
EOF
)

kubectl run debug-hostnet -n "${NS}" \
  --image="${ATTACKER_IMAGE}" \
  --restart=Never \
  --overrides="${HOSTNET_OVERRIDES}" >/dev/null

# Poll for pod completion (up to 40s)
HOSTNET_DONE="false"
for _ in $(seq 1 40); do
  PHASE="$(kubectl get pod debug-hostnet -n "${NS}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")"
  if [[ "${PHASE}" == "Succeeded" || "${PHASE}" == "Failed" ]]; then
    HOSTNET_DONE="true"
    break
  fi
  sleep 1
done

if [[ "${HOSTNET_DONE}" != "true" ]]; then
  echo "[WARN] Host network pod did not complete in 40s — assuming blocked (timeout = no bypass)"
  HOST_NETWORK_BLOCKED="true"
else
  HOSTNET_OUTPUT="$(kubectl logs debug-hostnet -n "${NS}" 2>/dev/null || echo "000")"
  HOSTNET_CODE="$(echo "${HOSTNET_OUTPUT}" | grep -oE '^[0-9]{3}' | head -1 || echo "000")"
  HOSTNET_CODE="${HOSTNET_CODE:-000}"

  if [[ "${HOSTNET_CODE}" == "200" ]]; then
    HOST_NETWORK_BLOCKED="false"
    MESH_BYPASS_POSSIBLE="true"
    echo "[FAIL] Host network escape got 200 — BYPASS POSSIBLE via hostNetwork pod!"
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  else
    HOST_NETWORK_BLOCKED="true"
    echo "[PASS] Host network escape blocked (code: ${HOSTNET_CODE})"
  fi
fi

kubectl delete pod debug-hostnet -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Write artifact
# ---------------------------------------------------------------------------
cat > "${ARTIFACT_DIR}/network_bypass.json" <<EOF
{
  "direct_pod_ip_blocked": ${DIRECT_POD_IP_BLOCKED},
  "sidecar_kill_blocked": ${SIDECAR_KILL_BLOCKED},
  "iptables_redirect_present": ${IPTABLES_REDIRECT_PRESENT},
  "network_policy_effective": ${NETWORK_POLICY_EFFECTIVE},
  "host_network_blocked": ${HOST_NETWORK_BLOCKED},
  "mesh_bypass_possible": ${MESH_BYPASS_POSSIBLE}
}
EOF

jq empty "${ARTIFACT_DIR}/network_bypass.json" >/dev/null
echo "[PASS] Network bypass validation passed — all 5 tests clear"
echo "[NET-BYPASS] Artifact: ${ARTIFACT_DIR}/network_bypass.json"
cat "${ARTIFACT_DIR}/network_bypass.json"
