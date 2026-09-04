#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_PATH="$REPO_ROOT/artifacts/north_south_boundary.json"
REGISTRY_HOST="${REGISTRY_HOST:-registry.threadforge.local}"
REGISTRY_PORT="${REGISTRY_PORT:-30500}"
REGISTRY_USER="${THREADFORGE_REGISTRY_USER:-threadforge}"
REGISTRY_PASSWORD="${THREADFORGE_REGISTRY_PASSWORD:-threadforge-dev-password}"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"
# shellcheck source=scripts/lib/registry_probe.sh
source "$REPO_ROOT/scripts/lib/registry_probe.sh"

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
fail_if_proof_mutation_blocked "verify_north_south_boundary.sh" "none"

cat > "$ARTIFACT_PATH" <<'EOF'
{
  "status": "RUNNING"
}
EOF

bash "$REPO_ROOT/scripts/verify/verify_north_south_ingress.sh" >/dev/null
write_case "external_ingress_validation" "PASS" "authorized=200 unauthorized=403 host=echo.threadforge.local"

node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')"
ingress_nodeport="$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')"
if [[ -z "$ingress_nodeport" ]]; then
  fail "istio-ingressgateway NodePort for port 80 is required for north-south verification"
fi

nodeport_services="$(kubectl get svc -A -o json | jq -r '
  .items[]
  | select(any(.spec.ports[]?; has("nodePort")))
  | "\(.metadata.namespace)/\(.metadata.name)"
' | sed '/^$/d')"
if [[ "$nodeport_services" != "istio-system/istio-ingressgateway" ]]; then
  write_case "nodeport_audit" "FAIL" "unexpected nodePort-exposing services: ${nodeport_services}"
  fail "unexpected NodePort service exposure detected"
fi
write_case "nodeport_audit" "PASS" "only istio-system/istio-ingressgateway exposes nodePorts"

set +e
direct_output="$(curl -sv --max-time 8 "http://${node_ip}:${ingress_nodeport}/" 2>&1)"
direct_rc=$?
set -e
if [[ "$direct_rc" -eq 0 ]] && printf '%s' "$direct_output" | grep -Eq 'HTTP/[0-9.]+ 2[0-9]{2}'; then
  write_case "direct_nodeport_blocked" "FAIL" "$direct_output"
  fail "direct NodePort request returned success"
fi
write_case "direct_nodeport_blocked" "PASS" "$direct_output"

set +e
unauth_output="$(curl -sv --max-time 8 -H 'Host: echo.threadforge.local' "http://${node_ip}:${ingress_nodeport}/metrics" 2>&1)"
unauth_rc=$?
set -e
if [[ "$unauth_rc" -eq 0 ]] && printf '%s' "$unauth_output" | grep -Eq 'HTTP/[0-9.]+ 2[0-9]{2}'; then
  write_case "unauthorized_ingress_denied" "FAIL" "$unauth_output"
  fail "unauthorized ingress path was allowed"
fi
write_case "unauthorized_ingress_denied" "PASS" "$unauth_output"

set +e
allow_output="$(curl -sv --max-time 8 -H 'Host: echo.threadforge.local' "http://${node_ip}:${ingress_nodeport}/" 2>&1)"
allow_rc=$?
set -e
if [[ "$allow_rc" -ne 0 ]] || ! printf '%s' "$allow_output" | grep -Eq 'HTTP/[0-9.]+ 200'; then
  write_case "allowed_ingress_path" "FAIL" "$allow_output"
  fail "allowed ingress path did not return 200"
fi
write_case "allowed_ingress_path" "PASS" "$allow_output"

echo_pod_ip="$(kubectl get pod -n threadforge-test -l app=echo -o jsonpath='{.items[0].status.podIP}')"
set +e
pod_output="$(curl -sv --max-time 8 "http://${echo_pod_ip}:80/" 2>&1)"
pod_rc=$?
set -e
if [[ "$pod_rc" -eq 0 ]] && printf '%s' "$pod_output" | grep -Eq 'HTTP/[0-9.]+ 2[0-9]{2}'; then
  write_case "direct_pod_ip_blocked" "FAIL" "$pod_output"
  fail "direct pod IP request returned success"
fi
write_case "direct_pod_ip_blocked" "PASS" "$pod_output"

test_client="$(kubectl get pod -n threadforge-test -l app=test-client -o jsonpath='{.items[0].metadata.name}')"
set +e
egress_output="$(kubectl exec -n threadforge-test -c test-client "$test_client" -- sh -c 'curl -sv --max-time 10 https://google.com 2>&1 | head -n 30')"
egress_rc=$?
set -e
if [[ "$egress_rc" -eq 0 ]] && printf '%s' "$egress_output" | grep -Eq '< HTTP/[0-9.]+ [23][0-9]{2}'; then
  write_case "external_egress_blocked" "FAIL" "$egress_output"
  fail "external egress from threadforge-test unexpectedly succeeded"
fi
write_case "external_egress_blocked" "PASS" "$egress_output"

set +e
registry_resolve="$(registry_probe_resolve "$REGISTRY_HOST" "$REGISTRY_PORT")"
registry_output="$(curl --resolve "$registry_resolve" -svk --max-time 10 "https://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/" 2>&1)"
registry_rc=$?
set -e
if [[ "$registry_rc" -eq 0 ]] && printf '%s' "$registry_output" | grep -Eq 'HTTP/[0-9.]+ 200'; then
  write_case "registry_anonymous_denied" "FAIL" "$registry_output"
  fail "registry /v2/ allowed anonymous 200 response"
fi
if [[ "$registry_rc" -eq 0 ]] && ! printf '%s' "$registry_output" | grep -Eq 'HTTP/[0-9.]+ (401|403)'; then
  write_case "registry_anonymous_denied" "FAIL" "$registry_output"
  fail "registry /v2/ did not return authorization denial"
fi
write_case "registry_anonymous_denied" "PASS" "$registry_output"

auth_registry_code="$(registry_probe_authenticated_status "$REGISTRY_HOST" "$REGISTRY_PORT" "$REGISTRY_USER" "$REGISTRY_PASSWORD")"
if [[ "$auth_registry_code" != "200" ]]; then
  write_case "registry_authenticated_allowed" "FAIL" "HTTP ${auth_registry_code}"
  fail "registry authenticated /v2/ probe failed"
fi
write_case "registry_authenticated_allowed" "PASS" "HTTP ${auth_registry_code}"

python3 - "$ARTIFACT_PATH" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text())
checks = [
  "external_ingress_validation",
    "nodeport_audit",
    "direct_nodeport_blocked",
    "unauthorized_ingress_denied",
    "allowed_ingress_path",
    "direct_pod_ip_blocked",
    "external_egress_blocked",
    "registry_anonymous_denied",
    "registry_authenticated_allowed",
]
doc["status"] = "PASS" if all(doc.get(c, {}).get("status") == "PASS" for c in checks) else "FAIL"
path.write_text(json.dumps(doc, indent=2) + "\n")
PY

echo "[PASS] north-south boundary checks verified"
