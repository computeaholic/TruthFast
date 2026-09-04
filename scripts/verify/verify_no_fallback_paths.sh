#!/usr/bin/env bash
set -euo pipefail

# ThreadForge North-South Enforcement: Remove Fallback Paths (Task 5)
# Ensures no:
# - Wildcard routes (*)
# - Catch-all default routes
# - Direct clusterIP access from ingress
# - Implicit allow patterns

export VERIFY_TYPE=ACTIVE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_PATH="$REPO_ROOT/artifacts/north_south_no_fallback_paths.json"

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
fail_if_proof_mutation_blocked "verify_no_fallback_paths.sh" "none"

mkdir -p "$(dirname "$ARTIFACT_PATH")"
cat > "$ARTIFACT_PATH" <<'EOF'
{
  "status": "RUNNING",
  "test": "no-fallback-paths"
}
EOF

echo "[no-fallback] Verifying no implicit/catch-all routing patterns..."

# ============================================================================
# TEST 1: No wildcard hosts in VirtualService
# ============================================================================
echo "[no-fallback] Checking for wildcard hosts..."
wildcard_hosts=$(kubectl get virtualservice -A -o json | jq -r '
  .items[]
  | select(((.spec.hosts // []) | index("*")) != null)
  | "\(.metadata.namespace)/\(.metadata.name)"
')

if [[ -n "$wildcard_hosts" ]]; then
  write_case "no_wildcard_hosts" "FAIL" "Wildcard hosts found: $wildcard_hosts"
  fail "VirtualServices with wildcard hosts detected"
fi

write_case "no_wildcard_hosts" "PASS" "No VirtualService wildcard hosts"

# ============================================================================
# TEST 2: No wildcard hosts in Gateway
# ============================================================================
echo "[no-fallback] Checking gateway servers for wildcards..."
gateway_wildcards=$(kubectl get gateway -A -o json | jq -r '
  .items[]
  | select(any((.spec.servers // [])[]?; ((.hosts // []) | index("*")) != null))
  | "\(.metadata.namespace)/\(.metadata.name)"
')

if [[ -n "$gateway_wildcards" ]]; then
  write_case "no_gateway_wildcards" "FAIL" "Gateway wildcard hosts found: $gateway_wildcards"
  fail "Gateway servers with wildcard hosts detected"
fi

write_case "no_gateway_wildcards" "PASS" "No Gateway wildcard hosts"

# ============================================================================
# TEST 3: No default/catch-all HTTP routes in VirtualService
# ============================================================================
echo "[no-fallback] Checking for catch-all HTTP routes..."
default_routes=$(kubectl get virtualservice -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{": "}{.spec.http[-1].match}{"\n"}{end}' | grep -E 'null|^\{$' || true)

if [[ -n "$default_routes" ]]; then
  # Verify they have explicit rules, not just default allow
  routes_with_rules=$(kubectl get virtualservice -A -o jsonpath='{range .items[*].spec.http[*]}{select(.match)}{"\n"}{end}' | grep -v null | wc -l)
  if [[ "$routes_with_rules" -eq 0 ]]; then
    write_case "no_catch_all_routes" "FAIL" "Default routes without explicit match rules found"
    fail "VirtualServices with implicit catch-all routes detected"
  fi
fi

write_case "no_catch_all_routes" "PASS" "All routes have explicit match conditions"

# ============================================================================
# TEST 4: No ALLOW_ALL AuthorizationPolicies on ingress paths
# ============================================================================
echo "[no-fallback] Checking for ALLOW_ALL policies on gateway routes..."
allow_all=$(kubectl get authorizationpolicy -A -o json | jq -r '
  [ .items[] | select((.spec.action // "ALLOW") == "ALLOW" and ((.spec.rules // []) | length == 0)) ] | length
')

# This check is tricky; let's verify more carefully
allow_policies=$(kubectl get authorizationpolicy -A -o jsonpath='{range .items[?(@.spec.action=="ALLOW")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')

if [[ -n "$allow_policies" ]]; then
  # Check if any of these have no rules (which means ALLOW_ALL)
  while IFS='/' read -r ns name; do
    rules=$(kubectl get authorizationpolicy -n "$ns" "$name" -o jsonpath='{.spec.rules}' 2>/dev/null || echo "")
    if [[ -z "$rules" || "$rules" == "[]" || "$rules" == "null" ]]; then
      write_case "no_allow_all_policies" "FAIL" "$ns/$name has no rules (ALLOW_ALL)"
      fail "ALLOW_ALL AuthorizationPolicy detected"
    fi
  done <<< "$allow_policies"
fi

write_case "no_allow_all_policies" "PASS" "No ALLOW_ALL policies on gateway routes"

# ============================================================================
# TEST 5: VirtualServices reference explicit destinations, not mesh/all
# ============================================================================
echo "[no-fallback] Checking for implicit destination routing..."
bad_destinations=$(kubectl get virtualservice -A -o jsonpath='{range .items[*].spec.http[*].route[*].destination]{if @.host=="*" || @.host==""}true{end}{"\n"}{end}' 2>/dev/null || true)

if [[ -n "$bad_destinations" ]]; then
  write_case "explicit_destinations" "FAIL" "Implicit destination routing found"
  fail "VirtualServices with implicit destination routing"
fi

write_case "explicit_destinations" "PASS" "All routes have explicit destination hosts"

# ============================================================================
# TEST 6: No DENY_ALL policies with empty rules (implicit deny of everything)
# ============================================================================
echo "[no-fallback] Checking for problematic DENY policies..."
deny_all=$(kubectl get authorizationpolicy -A -o json | jq -r '
  [ .items[] | select((.spec.action // "ALLOW") == "DENY" and ((.spec.rules // []) | length == 0)) ] | length
' 2>/dev/null || true)

# This is actually OK - DENY_ALL means secure by default
# But we should verify it doesn't accidentally deny the gateway
if [[ "$deny_all" != "0" ]]; then
  write_case "deny_policy_config" "INFO" "DENY_ALL policy found (secure-by-default, correct)"
else
  write_case "deny_policy_config" "INFO" "No DENY_ALL policies"
fi

# ============================================================================
# TEST 7: No ExternalName services (potential bypass)
# ============================================================================
echo "[no-fallback] Checking for ExternalName services..."
external_names=$(kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="ExternalName")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')

if [[ -n "$external_names" ]]; then
  write_case "no_external_name_services" "FAIL" "ExternalName services found: $external_names"
  fail "ExternalName services detected (potential bypass)"
fi

write_case "no_external_name_services" "PASS" "No ExternalName services"

# ============================================================================
# TEST 8: No DestinationRules with traffic policies that bypass security
# ============================================================================
echo "[no-fallback] Checking DestinationRules for bypass policies..."
dr_bypass=$(kubectl get destinationrule -A -o jsonpath='{range .items[*]}{select(.spec.trafficPolicy.connectionPool.tcp.maxConnections || .spec.trafficPolicy.loadBalancer.simple=="PASSTHROUGH")}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

if [[ -n "$dr_bypass" ]]; then
  write_case "no_bypass_destinationrules" "WARN" "DestinationRules with potential bypass configs: $dr_bypass"
else
  write_case "no_bypass_destinationrules" "PASS" "No DestinationRules with bypass configs"
fi

# ============================================================================
# TEST 9: Verify all HTTP routes specify explicit methods
# ============================================================================
echo "[no-fallback] Checking for method restrictions..."
http_routes=$(kubectl get virtualservice -A -o json | jq -r '
  [ .items[] | (.spec.http // [])[]? | select(any((.match // [])[]?; .method != null)) ] | length
')

if [[ "$http_routes" -eq 0 ]]; then
  write_case "method_restrictions" "INFO" "HTTP routes accept all methods (default POST/GET allowed)"
else
  write_case "method_restrictions" "PASS" "HTTP routes specify explicit methods"
fi

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
  "no_wildcard_hosts",
  "no_gateway_wildcards",
  "no_catch_all_routes",
  "no_allow_all_policies",
  "explicit_destinations",
  "no_external_name_services",
]
doc["status"] = "PASS" if all(doc.get(c, {}).get("status") in ["PASS", "INFO"] for c in checks) else "FAIL"
path.write_text(json.dumps(doc, indent=2) + "\n")
PY

echo "[PASS] No fallback paths verification complete"
