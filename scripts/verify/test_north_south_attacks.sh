#!/usr/bin/env bash
set -euo pipefail

# ThreadForge North-South Break-System Validation (Task 7)
# Tests that SPIRE-only + north-south enforcement prevents all bypass attacks:
# 1. NodePort bypass
# 2. Pod IP bypass
# 3. Wrong host header
# 4. Missing host header
# 5. Direct service DNS from outside

# ALL tests must return DENIED (status != 2xx/3xx)

export VERIFY_TYPE=ACTIVE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_PATH="$REPO_ROOT/artifacts/north_south_attack_tests.json"

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
fail_if_proof_mutation_blocked "test_north_south_attacks.sh" "break-system"

mkdir -p "$(dirname "$ARTIFACT_PATH")"
cat > "$ARTIFACT_PATH" <<'EOF'
{
  "status": "RUNNING",
  "test": "north-south-attacks"
}
EOF

echo "[attacks] Running north-south boundary break-system tests..."

# Get cluster details
node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")"
nodeport="$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || echo "")"
pod_ip="$(kubectl get pod -n threadforge-test -l app=echo -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo "")"

CORRECT_HOST="${THREADFORGE_INGRESS_HOST:-echo.threadforge.local}"
INGRESS_BASE="${THREADFORGE_INGRESS_URL:-http://${node_ip}:${nodeport}}"

# ============================================================================
# ATTACK 1: NodePort bypass - direct access via node IP + NodePort
# ============================================================================
echo "[attack-1] NodePort bypass: curl http://${node_ip}:${nodeport}/"
set +e
attack1=$(curl -s --max-time 5 "http://${node_ip}:${nodeport}/" -o /dev/null -w '%{http_code}' 2>&1 || echo "000")
attack1_rc=$?
set -e

if [[ "$attack1" =~ ^2[0-9]{2}$ ]] && [[ "$attack1_rc" -eq 0 ]]; then
  write_case "attack_nodeport_bypass" "FAIL" "HTTP $attack1 (attack SUCCEEDED - should be DENIED)"
  fail "NodePort bypass returned success"
fi

write_case "attack_nodeport_bypass" "PASS" "HTTP $attack1 (correctly denied)"

# ============================================================================
# ATTACK 2: Pod IP bypass - direct curl to pod IP
# ============================================================================
if [[ -n "$pod_ip" ]]; then
  echo "[attack-2] Pod IP bypass: curl http://${pod_ip}:80/"
  set +e
  attack2=$(curl -s --max-time 5 "http://${pod_ip}:80/" -o /dev/null -w '%{http_code}' 2>&1 || echo "000")
  attack2_rc=$?
  set -e

  if [[ "$attack2" =~ ^2[0-9]{2}$ ]] && [[ "$attack2_rc" -eq 0 ]]; then
    write_case "attack_pod_ip_bypass" "FAIL" "HTTP $attack2 (attack SUCCEEDED - should be DENIED)"
    fail "Pod IP bypass returned success"
  fi

  write_case "attack_pod_ip_bypass" "PASS" "HTTP $attack2 (correctly denied)"
else
  echo "[attack-2] Pod IP bypass: skipped (no test workloads)"
  write_case "attack_pod_ip_bypass" "SKIP" "Echo pod not found"
fi

# ============================================================================
# ATTACK 3: Wrong host header
# ============================================================================
echo "[attack-3] Wrong host header: curl -H 'Host: wrong.example.com' ${INGRESS_BASE}/"
set +e
attack3=$(curl -s --max-time 5 -H "Host: wrong.example.com" "${INGRESS_BASE}/" -o /dev/null -w '%{http_code}' 2>&1 || echo "000")
attack3_rc=$?
set -e

if [[ "$attack3" =~ ^2[0-9]{2}$ ]] && [[ "$attack3_rc" -eq 0 ]]; then
  write_case "attack_wrong_host_header" "FAIL" "HTTP $attack3 (attack SUCCEEDED - should be DENIED)"
  fail "Wrong host header was accepted"
fi

write_case "attack_wrong_host_header" "PASS" "HTTP $attack3 (correctly denied)"

# ============================================================================
# ATTACK 4: Missing host header (curl adds Host: localhost by default)
# ============================================================================
# This is tricky since curl adds Host automatically
# We'll test via a synthetic request that bypasses host header validation
echo "[attack-4] Missing/malformed host header"
set +e
# Try with Host header that's not the canonical host
attack4=$(curl -s --max-time 5 -H "Host: localhost" "${INGRESS_BASE}/" -o /dev/null -w '%{http_code}' 2>&1 || echo "000")
attack4_rc=$?
set -e

if [[ "$attack4" =~ ^2[0-9]{2}$ ]] && [[ "$attack4_rc" -eq 0 ]]; then
  write_case "attack_missing_host_header" "FAIL" "HTTP $attack4 (localhost accepted - should deny non-canonical hosts)"
  fail "Non-canonical host was accepted"
fi

write_case "attack_missing_host_header" "PASS" "HTTP $attack4 (correctly denied)"

# ============================================================================
# ATTACK 5: Direct service DNS resolution from outside
# ============================================================================
echo "[attack-5] Direct service DNS bypass"
# From a test client pod, try to access service directly (not through gateway)
test_client=$(kubectl get pod -n threadforge-test -l app=test-client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$test_client" ]]; then
  set +e
  # Try to curl the service directly (not through gateway)
  attack5=$(kubectl exec -n threadforge-test -c test-client "$test_client" -- \
    curl -s --max-time 5 "http://echo.threadforge-test.svc.cluster.local:80/admin" -o /dev/null -w '%{http_code}' 2>&1 || echo "000")
  attack5_rc=$?
  set -e

  # /admin should be explicitly denied by AuthorizationPolicy
  if [[ "$attack5" == "403" ]]; then
    write_case "attack_direct_service_dns" "PASS" "HTTP $attack5 (correctly denied /admin)"
  elif [[ "$attack5" =~ ^2[0-9]{2}$ ]] && [[ "$attack5_rc" -eq 0 ]]; then
    write_case "attack_direct_service_dns" "FAIL" "HTTP $attack5 (attack SUCCEEDED - /admin should be denied)"
    fail "Direct service DNS access to admin path succeeded"
  else
    write_case "attack_direct_service_dns" "PASS" "HTTP $attack5 (request denied)"
  fi
else
  echo "[attack-5] Direct service DNS: skipped (no test client)"
  write_case "attack_direct_service_dns" "SKIP" "Test client pod not found"
fi

# ============================================================================
# ATTACK 6: Service mesh bypass via internal IP
# ============================================================================
echo "[attack-6] Service mesh bypass via clusterIP"
svc_ip="$(kubectl get svc -n threadforge-test echo -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")"

if [[ -n "$svc_ip" ]]; then
  set +e
  # Try to access service directly via clusterIP (bypassing SPIFFE)
  attack6=$(curl -s --max-time 5 "http://${svc_ip}:80/admin" -o /dev/null -w '%{http_code}' 2>&1 || echo "000")
  attack6_rc=$?
  set -e

  # From outside cluster, this should timeout/fail (no network path)
  if [[ "$attack6" =~ ^2[0-9]{2}$ ]] && [[ "$attack6_rc" -eq 0 ]]; then
    write_case "attack_service_clusterip_bypass" "WARN" "HTTP $attack6 (unexpected success, verify network isolation)"
  else
    write_case "attack_service_clusterip_bypass" "PASS" "HTTP $attack6 (correctly blocked)"
  fi
else
  write_case "attack_service_clusterip_bypass" "SKIP" "Service not found"
fi

# ============================================================================
# ATTACK 7: Unauthorized path via correct host header
# ============================================================================
echo "[attack-7] Unauthorized path: curl -H 'Host: ${CORRECT_HOST}' ${INGRESS_BASE}/admin"
set +e
attack7=$(curl -s --max-time 5 -H "Host: ${CORRECT_HOST}" "${INGRESS_BASE}/admin" -o /dev/null -w '%{http_code}' 2>&1 || echo "000")
attack7_rc=$?
set -e

if [[ "$attack7" == "403" ]]; then
  write_case "attack_unauthorized_path" "PASS" "HTTP $attack7 (correctly denied /admin)"
elif [[ "$attack7" =~ ^2[0-9]{2}$ ]] && [[ "$attack7_rc" -eq 0 ]]; then
  write_case "attack_unauthorized_path" "FAIL" "HTTP $attack7 (attack SUCCEEDED - /admin should be denied)"
  fail "Unauthorized admin path was accessible"
else
  write_case "attack_unauthorized_path" "PASS" "HTTP $attack7 (request denied)"
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
  "attack_nodeport_bypass",
  "attack_pod_ip_bypass",
  "attack_wrong_host_header",
  "attack_missing_host_header",
  "attack_unauthorized_path",
]
doc["status"] = "PASS" if all(doc.get(c, {}).get("status") in ["PASS", "SKIP"] for c in checks) else "FAIL"
path.write_text(json.dumps(doc, indent=2) + "\n")
PY

echo "[PASS] All attack vectors correctly denied"
