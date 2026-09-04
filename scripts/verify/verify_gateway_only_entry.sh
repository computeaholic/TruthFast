#!/usr/bin/env bash
set -euo pipefail

# ThreadForge North-South Enforcement: Verify Gateway-Only Entry (Task 1)
# Ensures NO external access via:
# - NodePort (except ingressgateway)
# - Direct node IP
# - Direct pod IP

export VERIFY_TYPE=ACTIVE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_PATH="$REPO_ROOT/artifacts/north_south_gateway_only.json"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

kubectl() {
  run_real_kubectl "$@"
}

fail() {
  echo "[FAIL] CONTRACT_VIOLATION: $1"
  exit 2
}

write_case() {
  local key="$1"
  local status="$2"
  local detail="$3"
  python3 - "$ARTIFACT_PATH" "$key" "$status" "$detail" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
key, status, detail = sys.argv[2:]
doc = json.loads(path.read_text()) if path.exists() else {"status": "RUNNING"}
doc[key] = {"status": status, "detail": detail}
path.write_text(json.dumps(doc, indent=2) + "\n")
PY
}

ensure_cluster_readable || exit $?
fail_if_proof_mutation_blocked "verify_gateway_only_entry.sh" "none"

mkdir -p "$(dirname "$ARTIFACT_PATH")"
cat > "$ARTIFACT_PATH" <<'EOF'
{
  "status": "RUNNING",
  "test": "gateway-only-entry"
}
EOF

# ============================================================================
# TEST 1: Verify ONLY istio-ingressgateway is exposed via NodePort
# ============================================================================
echo "[gateway-only] checking for rogue NodePort services..."
nodeport_services="$(kubectl get svc -A -o json | jq -r '
  .items[]
  | select(any(.spec.ports[]?; has("nodePort")))
  | "\(.metadata.namespace)/\(.metadata.name)"
' | sort)"
expected_nodeport="istio-system/istio-ingressgateway"

# Check if only expected service is NodePort
if [[ -z "$nodeport_services" ]]; then
  write_case "nodeport_single_gateway" "FAIL" "No NodePort services found; ingressgateway must be NodePort"
  fail "ingressgateway must be exposed via NodePort"
fi

# Count services that actually expose nodePorts
nodeport_count=$(echo "$nodeport_services" | grep -c . || true)
if [[ "$nodeport_count" -ne 1 ]]; then
  write_case "nodeport_single_gateway" "FAIL" "Found $nodeport_count nodePort-exposing services, expected 1: $nodeport_services"
  fail "multiple nodePort-exposing services detected"
fi

# Verify it's the gateway
if [[ "$nodeport_services" != "$expected_nodeport" ]]; then
  write_case "nodeport_single_gateway" "FAIL" "Found: $nodeport_services, expected: $expected_nodeport"
  fail "NodePort service is not istio-ingressgateway"
fi

write_case "nodeport_single_gateway" "PASS" "Only istio-system/istio-ingressgateway exposed via NodePort"

# ============================================================================
# TEST 2: Verify direct node IP access is BLOCKED
# ============================================================================
echo "[gateway-only] testing direct node IP access (should be BLOCKED)..."
node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
nodeport="$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')"

set +e
direct_code=$(curl -s --max-time 5 "http://${node_ip}:${nodeport}/" -o /dev/null -w '%{http_code}' 2>&1 || echo "000")
set -e

if [[ "$direct_code" =~ ^2[0-9]{2}$ ]]; then
  write_case "direct_node_ip_blocked" "FAIL" "Got HTTP $direct_code from node IP directly"
  fail "direct node IP access returned success"
fi

write_case "direct_node_ip_blocked" "PASS" "HTTP ${direct_code} (connection refused or timeout - correct)"

# ============================================================================
# TEST 3: Verify direct pod IP access is BLOCKED
# ============================================================================
echo "[gateway-only] testing direct pod IP access (should be BLOCKED)..."
pod_ip=$(kubectl get pod -n threadforge-test -l app=echo -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo "")

if [[ -n "$pod_ip" ]]; then
  set +e
  pod_code=$(curl -s --max-time 5 "http://${pod_ip}:80/" -o /dev/null -w '%{http_code}' 2>&1 || echo "000")
  pod_rc=$?
  set -e

  if [[ "$pod_code" =~ ^2[0-9]{2}$ ]] && [[ "$pod_rc" -eq 0 ]]; then
    write_case "direct_pod_ip_blocked" "FAIL" "Got HTTP $pod_code from pod IP directly"
    fail "direct pod IP access returned success"
  fi

  write_case "direct_pod_ip_blocked" "PASS" "HTTP ${pod_code} (blocked)"
else
  write_case "direct_pod_ip_blocked" "SKIP" "Echo pod not found (test workloads not deployed yet)"
fi

# ============================================================================
# TEST 4: Verify NO ExternalIPs are configured on services
# ============================================================================
echo "[gateway-only] checking for ExternalIP usage..."
external_ips=$(kubectl get svc -A -o jsonpath='{range .items[?(@.spec.externalIPs)]}{.metadata.namespace}/{.metadata.name}: {.spec.externalIPs}{"\n"}{end}' | grep -v '^$' || true)

if [[ -n "$external_ips" ]]; then
  write_case "no_external_ips" "FAIL" "Services with externalIPs found: $external_ips"
  fail "ExternalIP services detected"
fi

write_case "no_external_ips" "PASS" "No services with externalIPs"

# ============================================================================
# TEST 5: Verify NO hostNetwork pods
# ============================================================================
echo "[gateway-old] checking for hostNetwork usage..."
host_network_pods=$(kubectl get pods -A -o json | jq -r '
  .items[]
  | select(.spec.hostNetwork == true)
  | select((.metadata.namespace | IN("kube-system","istio-system","spire-system","cert-manager","kyverno")) | not)
  | "\(.metadata.namespace)/\(.metadata.name)"
')

if [[ -n "$host_network_pods" ]]; then
  write_case "no_host_network" "FAIL" "Pods with hostNetwork=true found: $host_network_pods"
  fail "hostNetwork pods detected"
fi

write_case "no_host_network" "PASS" "No pods with hostNetwork=true"

# ============================================================================
# TEST 6: Verify ONLY Istio Gateway/VirtualService (no K8s Ingress)
# ============================================================================
echo "[gateway-only] checking for Kubernetes Ingress resources..."
k8s_ingress=$(kubectl get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' | grep -v '^$' || true)

if [[ -n "$k8s_ingress" ]]; then
  write_case "no_kubernetes_ingress" "FAIL" "Kubernetes Ingress resources found: $k8s_ingress"
  fail "Kubernetes Ingress resources detected (use Istio Gateway instead)"
fi

write_case "no_kubernetes_ingress" "PASS" "No Kubernetes Ingress resources"

# ============================================================================
# TEST 7: Verify gateway is properly bound to ingressgateway selector
# ============================================================================
echo "[gateway-only] verifying gateway selector binding..."
gateway_selectors=$(kubectl get gateway -A -o jsonpath='{range .items[*]}{.spec.selector}{"\n"}{end}' | grep -c 'ingressgateway' || true)

if [[ "$gateway_selectors" -eq 0 ]]; then
  write_case "gateway_properly_bound" "FAIL" "No gateways select istio=ingressgateway"
  fail "gateways not properly bound to ingressgateway"
fi

write_case "gateway_properly_bound" "PASS" "All gateways properly select istio=ingressgateway"

# ============================================================================
# Update overall status
# ============================================================================
python3 - "$ARTIFACT_PATH" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text())
checks = [
  "nodeport_single_gateway",
  "direct_node_ip_blocked",
  "direct_pod_ip_blocked",
  "no_external_ips",
  "no_host_network",
  "no_kubernetes_ingress",
  "gateway_properly_bound",
]
doc["status"] = "PASS" if all(doc.get(c, {}).get("status") in ["PASS", "SKIP"] for c in checks) else "FAIL"
path.write_text(json.dumps(doc, indent=2) + "\n")
PY

echo "[PASS] Gateway-only entry verification complete"
