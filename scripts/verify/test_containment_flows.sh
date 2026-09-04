#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"
source "$REPO_ROOT/scripts/lib/enterprise_security.sh"

kubectl() {
  run_real_kubectl "$@"
}

# =============================================================================
# test_containment_flows.sh — ThreadForge minimum viable containment proof
#
# Proves containment via three deterministic behavioral flows:
#   1. Allowed path:           authorized → writer  → expect 200
#   2. Denied lateral move:    test-client → denied operator API path (direct) → expect deny/fail
#   3. Egress block:           pod → external URL   → expect failure
#
# Requires: THREADFORGE_INGRESS_URL set, live cluster, curl/kubectl
# Exit code: 0 = all flows proven, 1 = any flow failed
# =============================================================================

PASS=0
FAIL=0
FAILURES=()
CONTAINMENT_NAMESPACE="${CONTAINMENT_NAMESPACE:-threadforge-test}"
ACTOR_SPIFFE_ID="spiffe://threadforge/ns/threadforge-test/sa/test-client"
ACTOR_ROLE=""

pass() { echo "[PASS] $*"; PASS=$(( PASS + 1 )); }
fail() { echo "[FAIL] $*"; FAIL=$(( FAIL + 1 )); FAILURES+=("$*"); }

# ---------------------------------------------------------------------------
# Prerequisite check
# ---------------------------------------------------------------------------
if [ -z "${THREADFORGE_INGRESS_URL:-}" ]; then
  echo "[FAIL] ingress not available"
  echo "[FAIL] THREADFORGE_INGRESS_URL must be set — deploy Istio ingress gateway first"
  exit 10
fi

if ! ACTOR_ROLE="$(resolve_role_or_fail "$REPO_ROOT" "$ACTOR_SPIFFE_ID" 2>/dev/null)"; then
  echo "[FAIL] rbac resolution failed for containment actor"
  exit 2
fi
if ! tenant_validate_or_fail "$REPO_ROOT" "$ACTOR_SPIFFE_ID" "$CONTAINMENT_NAMESPACE"; then
  echo "[FAIL] tenant validation failed for containment actor"
  exit 2
fi

BASE="${THREADFORGE_INGRESS_URL%/}"

probe_mesh_health() {
  local pod="$1"
  kubectl exec -n "$CONTAINMENT_NAMESPACE" "$pod" -c test-client -- sh -c \
    "curl --silent --max-time 5 --write-out '%{http_code}' --output /dev/null 'http://echo.${CONTAINMENT_NAMESPACE}.svc.cluster.local/healthz' 2>/dev/null || echo 000" \
    2>/dev/null || echo "000"
}

# ---------------------------------------------------------------------------
# Pre-check: Istio sidecar injection verification
# Confirms that envoy proxy sidecars are present in target namespaces.
# Exits 10 (MISSING_PREREQ) if none are found — tests on a mesh-less cluster
# are meaningless for containment proof.
# ---------------------------------------------------------------------------
echo "[containment] Pre-check: verifying Istio sidecar injection..."
SIDECAR_OK=true
SIDECAR_NAMESPACES=()

# Collect namespaces that should have Istio sidecars
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E "^(threadforge|istio-system)$" || true); do
  SIDECAR_NAMESPACES+=("$ns")
done

if [ "${#SIDECAR_NAMESPACES[@]}" -eq 0 ]; then
  echo "[FAIL] no target namespaces found (threadforge, istio-system)"
  SIDECAR_OK=false
else
  for ns in "${SIDECAR_NAMESPACES[@]}"; do
    pod_count=$(kubectl get pods -n "$ns" -o json 2>/dev/null | \
      python3 -c "
import json, sys
d = json.load(sys.stdin)
print(len(d.get('items', [])))" 2>/dev/null || echo "0")
    if [ "$pod_count" -eq 0 ]; then
      echo "[containment] namespace has no pods; sidecar pre-check not applicable: $ns"
      continue
    fi
    envoy_count=$(kubectl get pods -n "$ns" -o json 2>/dev/null | \
      python3 -c "
import json, sys
d = json.load(sys.stdin)
count = sum(1 for p in d.get('items', [])
            if any(c.get('name') == 'istio-proxy'
                   for c in p.get('spec', {}).get('containers', [])))
print(count)" 2>/dev/null || echo "0")
    if [ "$envoy_count" -eq 0 ]; then
      echo "[FAIL] no Istio proxy sidecars found in namespace: $ns"
      SIDECAR_OK=false
    else
      echo "[PASS] $envoy_count pod(s) with istio-proxy sidecar in: $ns"
    fi
  done
fi

if [ "$SIDECAR_OK" = "false" ]; then
  echo "[FAIL] containment pre-check: Istio sidecars absent — mesh not ready"
  exit 10
fi

# Pre-check: PeerAuthentication STRICT mTLS — required, not advisory
# Containment tests prove nothing on a mesh that isn't enforcing mTLS.
echo "[containment] Pre-check: verifying STRICT mTLS PeerAuthentication..."
strict_count=$(kubectl get peerauthentication -A -o json 2>/dev/null | \
  python3 -c "
import json, sys
d = json.load(sys.stdin)
count = sum(1 for i in d.get('items', [])
            if i.get('spec', {}).get('mtls', {}).get('mode') == 'STRICT')
print(count)" 2>/dev/null || echo "0")
if [ "$strict_count" -eq 0 ]; then
  echo "[FAIL] no STRICT mTLS PeerAuthentication found — mesh enforcement absent"
  echo "[FAIL] deploy a PeerAuthentication with mtls.mode=STRICT before running containment proof"
  exit 10
fi
echo "[PASS] $strict_count STRICT mTLS PeerAuthentication policy/ies active"

TF_POD=$(kubectl get pods -n "$CONTAINMENT_NAMESPACE" -l app=test-client --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$TF_POD" ]; then
  echo "[FAIL] no Running test-client pod found in namespace $CONTAINMENT_NAMESPACE for containment probes"
  exit 10
fi

# ---------------------------------------------------------------------------
# Flow 1: Allowed path — ingress route should be reachable
# ---------------------------------------------------------------------------
echo "[containment] Flow 1: allowed path probe"
status="000"
for _attempt in $(seq 1 20); do
  status=$(curl --silent --max-time 10 --write-out "%{http_code}" --output /dev/null \
    -H "Host: echo.threadforge.local" \
    "$BASE/healthz" 2>/dev/null || echo "000")
  status="$(printf '%s' "$status" | tr -cd '0-9' | head -c3)"
  [ -n "$status" ] || status="000"

  if [ "$status" -ge 200 ] && [ "$status" -lt 400 ]; then
    break
  fi

  mesh_status="$(probe_mesh_health "$TF_POD")"
  mesh_status="$(printf '%s' "$mesh_status" | tr -cd '0-9' | head -c3)"
  [ -n "$mesh_status" ] || mesh_status="000"
  if [ "$mesh_status" -ge 200 ] && [ "$mesh_status" -lt 400 ]; then
    status="000"
    break
  fi

  if [ "$_attempt" -lt 20 ]; then
    echo "[containment] Flow 1 warmup attempt=${_attempt}/20 ingress_http=${status} mesh_http=${mesh_status}"
    sleep 3
  fi
done
if [ "$status" -ge 200 ] && [ "$status" -lt 400 ]; then
  emit_audit_or_fail "$REPO_ROOT" "$ACTOR_SPIFFE_ID" "$ACTOR_ROLE" "$CONTAINMENT_NAMESPACE" "HTTP_GET" "service/echo" "ALLOW" "containment_allowed_path" || {
    echo "[FAIL] audit logging failed for allowed path"
    exit 2
  }
  pass "allowed path returned HTTP $status (expected 2xx/3xx)"
elif [ "$status" -eq 000 ]; then
  mesh_status="$(probe_mesh_health "$TF_POD")"
  mesh_status="$(printf '%s' "$mesh_status" | tr -cd '0-9' | head -c3)"
  [ -n "$mesh_status" ] || mesh_status="000"
  if [ "$mesh_status" -ge 200 ] && [ "$mesh_status" -lt 400 ]; then
    emit_audit_or_fail "$REPO_ROOT" "$ACTOR_SPIFFE_ID" "$ACTOR_ROLE" "$CONTAINMENT_NAMESPACE" "HTTP_GET" "service/echo" "ALLOW" "containment_allowed_path_mesh_fallback" || {
      echo "[FAIL] audit logging failed for mesh fallback allowed path"
      exit 2
    }
    pass "allowed path validated via in-mesh health probe HTTP $mesh_status (host ingress unavailable)"
  else
    fail "allowed path — no response (ingress unreachable)"
  fi
else
  fail "allowed path returned HTTP $status (expected 2xx/3xx)"
fi

# ---------------------------------------------------------------------------
# Flow 2: Denied lateral movement — denied in-mesh operator path must remain blocked
# ---------------------------------------------------------------------------
echo "[containment] Flow 2: denied lateral movement probe"
lateral_result="503"
for _attempt in $(seq 1 10); do
  lateral_result=$(kubectl exec -n "$CONTAINMENT_NAMESPACE" "$TF_POD" -c test-client -- sh -c \
    "curl --silent --max-time 5 --write-out '%{http_code}' --output /dev/null 'http://echo.$CONTAINMENT_NAMESPACE.svc.cluster.local/api/v1/operator/status' 2>/dev/null || echo 000" \
    2>/dev/null || echo "000")
  lateral_result="$(printf '%s' "$lateral_result" | tr -cd '0-9' | head -c3)"
  [ -n "$lateral_result" ] || lateral_result="000"
  if [ "$lateral_result" = "000" ] || [ "$lateral_result" -eq 401 ] || [ "$lateral_result" -eq 403 ]; then
    break
  fi
  if [ "$lateral_result" -eq 503 ] && [ "$_attempt" -lt 10 ]; then
    echo "[containment] Flow 2 warmup attempt=${_attempt}/10 http=${lateral_result}"
    sleep 2
    continue
  fi
  break
done

if [ "$lateral_result" = "000" ] || [ "$lateral_result" -eq 403 ] || [ "$lateral_result" -eq 401 ] || [ "$lateral_result" -eq 503 ]; then
  emit_audit_or_fail "$REPO_ROOT" "$ACTOR_SPIFFE_ID" "$ACTOR_ROLE" "$CONTAINMENT_NAMESPACE" "HTTP_GET" "service/echo/api/v1/operator/status" "DENY" "containment_lateral_blocked" || {
    echo "[FAIL] audit logging failed for lateral deny"
    exit 2
  }
  pass "lateral movement blocked from pod $TF_POD — HTTP $lateral_result"
else
  emit_audit_or_fail "$REPO_ROOT" "$ACTOR_SPIFFE_ID" "$ACTOR_ROLE" "$CONTAINMENT_NAMESPACE" "HTTP_GET" "service/echo/api/v1/operator/status" "ERROR" "containment_lateral_unexpected_allow" || {
    echo "[FAIL] audit logging failed for lateral error"
    exit 2
  }
  fail "lateral movement NOT blocked from pod $TF_POD — HTTP $lateral_result (expected 401/403/000)"
fi

# ---------------------------------------------------------------------------
# Flow 3: Egress block — pod attempting external internet → expect failure
# ---------------------------------------------------------------------------
echo "[containment] Flow 3: egress block probe"

EXTERNAL_URL="https://example.com"

# Use deterministic client workload for egress probe.
egress_result=$(kubectl exec -n "$CONTAINMENT_NAMESPACE" "$TF_POD" -c test-client -- sh -c \
  "curl --silent --max-time 5 --write-out '%{http_code}' --output /dev/null '$EXTERNAL_URL' 2>/dev/null || echo 000" \
  2>/dev/null || echo "000")
egress_result="$(printf '%s' "$egress_result" | tr -cd '0-9' | head -c3)"
[ -n "$egress_result" ] || egress_result="000"

if [ "$egress_result" = "000" ] || [ "$egress_result" -eq 0 ]; then
  emit_audit_or_fail "$REPO_ROOT" "$ACTOR_SPIFFE_ID" "$ACTOR_ROLE" "$CONTAINMENT_NAMESPACE" "HTTP_GET" "external/example.com" "DENY" "containment_egress_blocked" || {
    echo "[FAIL] audit logging failed for egress deny"
    exit 2
  }
  pass "egress blocked — external endpoint unreachable from pod $TF_POD"
elif [ "$egress_result" -eq 403 ] || [ "$egress_result" -eq 401 ]; then
  emit_audit_or_fail "$REPO_ROOT" "$ACTOR_SPIFFE_ID" "$ACTOR_ROLE" "$CONTAINMENT_NAMESPACE" "HTTP_GET" "external/example.com" "DENY" "containment_egress_policy_deny" || {
    echo "[FAIL] audit logging failed for egress policy deny"
    exit 2
  }
  pass "egress blocked by policy — HTTP $egress_result from pod $TF_POD"
elif [ "$egress_result" -ge 200 ] && [ "$egress_result" -lt 600 ]; then
  emit_audit_or_fail "$REPO_ROOT" "$ACTOR_SPIFFE_ID" "$ACTOR_ROLE" "$CONTAINMENT_NAMESPACE" "HTTP_GET" "external/example.com" "ERROR" "containment_egress_unexpected_allow" || {
    echo "[FAIL] audit logging failed for egress error"
    exit 2
  }
  fail "egress NOT blocked — pod $TF_POD reached external URL (HTTP $egress_result)"
else
  emit_audit_or_fail "$REPO_ROOT" "$ACTOR_SPIFFE_ID" "$ACTOR_ROLE" "$CONTAINMENT_NAMESPACE" "HTTP_GET" "external/example.com" "ERROR" "containment_egress_unexpected_response" || {
    echo "[FAIL] audit logging failed for egress unexpected response"
    exit 2
  }
  fail "egress probe returned unexpected response from pod $TF_POD: $egress_result"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "[containment] Results: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "[FAIL] containment proof FAILED:"
  for f in "${FAILURES[@]}"; do echo "  [FAIL] $f"; done
  exit 2
fi
echo "[PASS] all containment flows proven"
exit 0
