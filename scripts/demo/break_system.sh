#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/scripts/lib/enterprise_security.sh"

echo "[STEP] break-system prerequisites"
bash "$REPO_ROOT/scripts/verify/ensure_test_workload.sh"
bash "$REPO_ROOT/scripts/verify/verify_system_integrity.sh"
echo "[PASS] break-system prerequisites"

TEST_IMAGE="${BREAK_SYSTEM_TEST_IMAGE:-registry.threadforge.local:30500/mirror/docker.io/library/busybox@sha256:bfdec45b06a48dbc7d261ace48cec2d74849ecfc5129662c979f656cb31df469}"
TMP_DIR="$(mktemp -d)"
FAILURES=0
SCALE_DOWN_DONE="false"
NEW_TEST_CLIENT_POD=""
ORIGINAL_TEST_CLIENT_POD=""
ACTIVE_TEST_CLIENT_POD=""
AUDIT_LOG_PATH="${THREADFORGE_AUDIT_LOG_PATH:-$REPO_ROOT/artifacts/audit/audit.log}"
TEMPO_ENTRY_DELETED="false"

restore_observability_spire_entries() {
  SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN:-identity.threadforge.local}" \
    bash "$REPO_ROOT/scripts/infra/reconcile_observability_spire_entries.sh" --apply >/dev/null
}

cleanup() {
  kubectl -n threadforge-test delete pod break-sidecar-opt-out --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n threadforge-test delete pod break-external-registry --ignore-not-found >/dev/null 2>&1 || true

  # Restore Tempo SPIRE entry if the break test deleted it.
  if [[ "$TEMPO_ENTRY_DELETED" == "true" ]]; then
    restore_observability_spire_entries >/dev/null 2>&1 || true
  fi

  if [[ "$SCALE_DOWN_DONE" == "true" ]]; then
    kubectl -n spire-system scale statefulset/spire-server --replicas=1 >/dev/null 2>&1 || true
    kubectl -n spire-system rollout status statefulset/spire-server --timeout=180s >/dev/null 2>&1 || true
    kubectl -n istio-system rollout status deployment/spire-csr --timeout=180s >/dev/null 2>&1 || true
    bash "$REPO_ROOT/scripts/verify/wait_for_data_plane_ready.sh" >/dev/null 2>&1 || true
  fi

  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

print_result_block() {
  local name="$1"
  local attempt="$2"
  local blocked="$3"

  echo "[BREAK TEST] ${name}"
  echo "ATTEMPT: ${attempt}"
  if [[ "$blocked" == "true" ]]; then
    echo "RESULT: BLOCKED"
    echo "EXPECTED: BLOCKED"
    echo "STATUS: PASS"
  else
    echo "RESULT: ALLOWED"
    echo "EXPECTED: BLOCKED"
    echo "STATUS: FAIL"
    FAILURES=$((FAILURES + 1))
  fi
  echo
}

print_denied_block() {
  local name="$1"
  local attempt="$2"
  local denied="$3"

  echo "[BREAK TEST] ${name}"
  echo "ATTEMPT: ${attempt}"
  if [[ "$denied" == "true" ]]; then
    echo "RESULT: DENIED"
    echo "EXPECTED: DENIED"
    echo "STATUS: DENIED"
  else
    echo "RESULT: ALLOWED"
    echo "EXPECTED: DENIED"
    echo "STATUS: ALLOWED"
    FAILURES=$((FAILURES + 1))
  fi
  echo
}

audit_event_must_exist() {
  local needle="$1"
  if [[ ! -f "$AUDIT_LOG_PATH" ]]; then
    return 1
  fi
  grep -q "$needle" "$AUDIT_LOG_PATH"
}

restore_spire_identity() {
  kubectl -n spire-system scale statefulset/spire-server --replicas=1 >/dev/null
  kubectl -n spire-system rollout status statefulset/spire-server --timeout=180s >/dev/null
  kubectl -n istio-system rollout status deployment/spire-csr --timeout=180s >/dev/null
  bash "$REPO_ROOT/scripts/verify/wait_for_data_plane_ready.sh" >/dev/null
}

await_test_client_pod() {
  local previous="$1"
  kubectl -n threadforge-test wait --for=condition=Ready pod -l app=test-client --timeout=180s >/dev/null
  local pod
  pod="$(kubectl get pod -n threadforge-test -l app=test-client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$pod" && "$pod" != "$previous" ]]; then
    echo "$pod"
    return 0
  fi
  return 1
}

attempt_request_from_test_client() {
  local pod_name="$1"
  kubectl exec -n threadforge-test -c test-client "$pod_name" -- sh -c 'curl -fsS --max-time 10 http://echo.threadforge-test.svc.cluster.local/' 2>&1
}

ORIGINAL_TEST_CLIENT_POD="$(kubectl get pod -n threadforge-test -l app=test-client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$ORIGINAL_TEST_CLIENT_POD" ]]; then
  echo "[FAIL] missing threadforge-test test-client pod"
  exit 2
fi

kubectl -n spire-system scale statefulset/spire-server --replicas=0 >/dev/null
kubectl -n spire-system wait --for=jsonpath='{.status.replicas}'=0 statefulset/spire-server --timeout=180s >/dev/null
SCALE_DOWN_DONE="true"

kubectl -n threadforge-test delete pod "$ORIGINAL_TEST_CLIENT_POD" --ignore-not-found >/dev/null
NEW_TEST_CLIENT_POD="$(await_test_client_pod "$ORIGINAL_TEST_CLIENT_POD" || true)"

IDENTITY_ATTEMPT="scale spire-server=0, replace test-client pod, request echo service"
IDENTITY_OUTPUT_FILE="$TMP_DIR/identity_out.txt"
set +e
if [[ -n "$NEW_TEST_CLIENT_POD" ]]; then
  attempt_request_from_test_client "$NEW_TEST_CLIENT_POD" >"$IDENTITY_OUTPUT_FILE" 2>&1
  IDENTITY_RC=$?
else
  echo "new test-client pod was not created" >"$IDENTITY_OUTPUT_FILE"
  IDENTITY_RC=1
fi
set -e
IDENTITY_BLOCKED="false"
if [[ "$IDENTITY_RC" -ne 0 ]]; then
  IDENTITY_BLOCKED="true"
fi
print_result_block "Identity outage" "$IDENTITY_ATTEMPT" "$IDENTITY_BLOCKED"
if [[ "$IDENTITY_BLOCKED" == "true" ]]; then
  echo "[BREAK] identity outage -> FAIL CLOSED (expected)"
fi

SESSION_ATTEMPT="reuse existing post-outage test-client pod and repeat request"
SESSION_OUTPUT_FILE="$TMP_DIR/session_out.txt"
set +e
if [[ -n "$NEW_TEST_CLIENT_POD" ]]; then
  attempt_request_from_test_client "$NEW_TEST_CLIENT_POD" >"$SESSION_OUTPUT_FILE" 2>&1
  SESSION_RC=$?
else
  echo "no reusable post-outage pod available" >"$SESSION_OUTPUT_FILE"
  SESSION_RC=1
fi
set -e
SESSION_BLOCKED="false"
if [[ "$SESSION_RC" -ne 0 ]]; then
  SESSION_BLOCKED="true"
fi
print_result_block "Existing session reuse" "$SESSION_ATTEMPT" "$SESSION_BLOCKED"

restore_spire_identity
SCALE_DOWN_DONE="false"
kubectl -n threadforge-test wait --for=condition=Ready pod -l app=test-client --timeout=180s >/dev/null
ACTIVE_TEST_CLIENT_POD="$(kubectl get pod -n threadforge-test -l app=test-client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$ACTIVE_TEST_CLIENT_POD" ]]; then
  echo "[FAIL] test-client pod unavailable after SPIRE recovery"
  exit 2
fi

SIDECAR_ATTEMPT="create pod with sidecar.istio.io/inject=false"
SIDECAR_OUTPUT_FILE="$TMP_DIR/sidecar_out.txt"
set +e
cat <<EOF | kubectl apply -f - >"$SIDECAR_OUTPUT_FILE" 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: break-sidecar-opt-out
  namespace: threadforge-test
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  containers:
    - name: app
      image: ${TEST_IMAGE}
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 200m
          memory: 128Mi
EOF
SIDECAR_RC=$?
set -e
SIDECAR_BLOCKED="false"
if [[ "$SIDECAR_RC" -ne 0 ]]; then
  SIDECAR_BLOCKED="true"
fi
print_result_block "Sidecar bypass attempt" "$SIDECAR_ATTEMPT" "$SIDECAR_BLOCKED"

EPHEMERAL_ATTEMPT="kubectl debug on running echo pod"
EPHEMERAL_OUTPUT_FILE="$TMP_DIR/ephemeral_out.txt"
ECHO_POD="$(kubectl get pod -n threadforge-test -l app=echo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
set +e
if [[ -n "$ECHO_POD" ]]; then
  kubectl debug -n threadforge-test "pod/${ECHO_POD}" --target=echo --image="$TEST_IMAGE" -- sleep 5 >"$EPHEMERAL_OUTPUT_FILE" 2>&1
  EPHEMERAL_RC=$?
else
  echo "echo pod not found" >"$EPHEMERAL_OUTPUT_FILE"
  EPHEMERAL_RC=1
fi
set -e
EPHEMERAL_BLOCKED="false"
if [[ "$EPHEMERAL_RC" -ne 0 ]]; then
  EPHEMERAL_BLOCKED="true"
fi
print_result_block "Ephemeral container injection" "$EPHEMERAL_ATTEMPT" "$EPHEMERAL_BLOCKED"

EXTERNAL_ATTEMPT="kubectl run from docker.io/nginx"
EXTERNAL_OUTPUT_FILE="$TMP_DIR/external_out.txt"
set +e
kubectl run break-external-registry -n threadforge-test --image=docker.io/library/nginx:latest --restart=Never >"$EXTERNAL_OUTPUT_FILE" 2>&1
EXTERNAL_RC=$?
set -e
EXTERNAL_BLOCKED="false"
if [[ "$EXTERNAL_RC" -ne 0 ]]; then
  EXTERNAL_BLOCKED="true"
fi
print_result_block "External registry image" "$EXTERNAL_ATTEMPT" "$EXTERNAL_BLOCKED"

EAST_WEST_ATTEMPT="from threadforge-test test-client to prometheus.observability"
EAST_WEST_OUTPUT_FILE="$TMP_DIR/eastwest_out.txt"
set +e
if [[ -n "$ACTIVE_TEST_CLIENT_POD" ]]; then
  kubectl exec -n threadforge-test -c test-client "$ACTIVE_TEST_CLIENT_POD" -- sh -c 'curl -sv --max-time 10 http://prometheus.observability.svc.cluster.local:9090/-/ready -o /dev/null' >"$EAST_WEST_OUTPUT_FILE" 2>&1
  EAST_WEST_RC=$?
else
  echo "test-client pod unavailable" >"$EAST_WEST_OUTPUT_FILE"
  EAST_WEST_RC=1
fi
set -e
EAST_WEST_BLOCKED="false"
if grep -Eq 'HTTP/[0-9.]+ 403' "$EAST_WEST_OUTPUT_FILE"; then
  EAST_WEST_BLOCKED="true"
elif [[ "$EAST_WEST_RC" -ne 0 ]]; then
  EAST_WEST_BLOCKED="true"
fi
print_result_block "East-west lateral movement" "$EAST_WEST_ATTEMPT" "$EAST_WEST_BLOCKED"

NORTH_SOUTH_ATTEMPT="direct NodePort access, direct service IP access, and anonymous registry access"
NORTH_SOUTH_OUTPUT_FILE="$TMP_DIR/northsouth_out.txt"
NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}' 2>/dev/null || true)"
INGRESS_NODEPORT="$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || true)"
ECHO_SERVICE_IP="$(kubectl get svc echo -n threadforge-test -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
NODEPORT_CODE="000"
SERVICE_IP_CODE="000"
REGISTRY_CODE="000"
if [[ -n "$NODE_IP" && -n "$INGRESS_NODEPORT" ]]; then
  NODEPORT_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "http://${NODE_IP}:${INGRESS_NODEPORT}/" || true)"
fi
if [[ -n "$ECHO_SERVICE_IP" ]]; then
  SERVICE_IP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "http://${ECHO_SERVICE_IP}:80/" || true)"
fi
REGISTRY_CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 https://registry.threadforge.local:30500/v2/ || true)"
{
  echo "nodeport_http_code=${NODEPORT_CODE}"
  echo "service_ip_http_code=${SERVICE_IP_CODE}"
  echo "registry_anon_http_code=${REGISTRY_CODE}"
} >"$NORTH_SOUTH_OUTPUT_FILE"
NORTH_SOUTH_BLOCKED="false"
if [[ "$NODEPORT_CODE" != 2* ]] \
  && [[ "$SERVICE_IP_CODE" != 2* ]] \
  && [[ "$REGISTRY_CODE" == "401" || "$REGISTRY_CODE" == "403" ]]; then
  NORTH_SOUTH_BLOCKED="true"
fi
print_result_block "North-south ingress bypass" "$NORTH_SOUTH_ATTEMPT" "$NORTH_SOUTH_BLOCKED"

RBAC_ATTEMPT="resolve unmapped SPIFFE identity to role"
RBAC_BLOCKED="false"
if resolve_role_or_fail "$REPO_ROOT" "spiffe://threadforge/ns/threadforge-test/sa/unmapped-breaker" >/dev/null 2>&1; then
  RBAC_BLOCKED="false"
else
  RBAC_BLOCKED="true"
  emit_audit_or_fail "$REPO_ROOT" "spiffe://threadforge/ns/threadforge-test/sa/unmapped-breaker" "unknown" "threadforge-test" "RBAC_RESOLVE" "break-system/rbac" "DENY" "rbac_mapping_missing" "$AUDIT_LOG_PATH" >/dev/null 2>&1 || true
  if ! audit_event_must_exist "rbac_mapping_missing"; then
    RBAC_BLOCKED="false"
  fi
fi
print_result_block "RBAC failure (unmapped identity)" "$RBAC_ATTEMPT" "$RBAC_BLOCKED"

AUDIT_BYPASS_ATTEMPT="simulate action path that skips required audit schema"
AUDIT_BYPASS_BLOCKED="false"
if python3 "$REPO_ROOT/platform/runtime/audit/audit_logger.py" \
  --actor-spiffe-id "spiffe://threadforge/ns/threadforge-test/sa/test-client" \
  --actor-role "" \
  --namespace "threadforge-test" \
  --action "AUDIT_BYPASS" \
  --resource "break-system/audit" \
  --result "ALLOW" \
  --reason "forced_bypass" \
  --audit-log-path "$AUDIT_LOG_PATH" >/dev/null 2>&1; then
  AUDIT_BYPASS_BLOCKED="false"
else
  AUDIT_BYPASS_BLOCKED="true"
fi
print_result_block "Audit bypass attempt" "$AUDIT_BYPASS_ATTEMPT" "$AUDIT_BYPASS_BLOCKED"

TENANT_ESCAPE_ATTEMPT="validate and probe threadforge-test -> observability escape"
TENANT_ESCAPE_BLOCKED="false"
if tenant_validate_or_fail "$REPO_ROOT" "spiffe://threadforge/ns/threadforge-test/sa/test-client" "observability" >/dev/null 2>&1; then
  TENANT_ESCAPE_BLOCKED="false"
else
  if [[ -n "$ACTIVE_TEST_CLIENT_POD" ]]; then
    TENANT_ESCAPE_CODE="$(kubectl exec -n threadforge-test -c test-client "$ACTIVE_TEST_CLIENT_POD" -- sh -c 'curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://prometheus.observability.svc.cluster.local:9090/-/ready' 2>/dev/null || echo 000)"
    TENANT_ESCAPE_CODE="${TENANT_ESCAPE_CODE:0:3}"
    if [[ "$TENANT_ESCAPE_CODE" == "403" || "$TENANT_ESCAPE_CODE" == "401" || "$TENANT_ESCAPE_CODE" == "000" ]]; then
      TENANT_ESCAPE_BLOCKED="true"
      emit_audit_or_fail "$REPO_ROOT" "spiffe://threadforge/ns/threadforge-test/sa/test-client" "test-client" "observability" "HTTP_GET" "service/prometheus" "DENY" "tenant_escape_blocked" "$AUDIT_LOG_PATH" >/dev/null 2>&1 || true
    fi
  fi
fi
print_result_block "Tenant escape attempt" "$TENANT_ESCAPE_ATTEMPT" "$TENANT_ESCAPE_BLOCKED"

GOVERNANCE_PROOF_GAP_ATTEMPT="simulate HEAD without matching proof commit artifact"
GOVERNANCE_PROOF_GAP_BLOCKED="false"
GOVERNANCE_PROOF_DIR="$TMP_DIR/governance-proof-gap"
mkdir -p "$GOVERNANCE_PROOF_DIR"
cat > "$GOVERNANCE_PROOF_DIR/status.json" <<'EOF'
{
  "final": "PASS",
  "signed": true,
  "verified": true,
  "evidence": {
    "signed": true,
    "verified": true
  }
}
EOF
echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" > "$GOVERNANCE_PROOF_DIR/commit.sha"
echo "placeholder" > "$GOVERNANCE_PROOF_DIR/hashes.txt"
echo '{"consistent": true}' > "$GOVERNANCE_PROOF_DIR/determinism.json"
set +e
VERIFY_MAIN_TEST_MODE=true VERIFY_MAIN_SKIP_REMOTE_CHECKS=true VERIFY_MAIN_PROOF_DIR="$GOVERNANCE_PROOF_DIR" \
  bash "$REPO_ROOT/scripts/verify/verify_main_integrity.sh" > "$TMP_DIR/governance_proof_gap_out.txt" 2>&1
GOVERNANCE_PROOF_GAP_RC=$?
set -e
if [[ "$GOVERNANCE_PROOF_GAP_RC" -ne 0 ]] && grep -q "\[FAIL\] UNVERIFIED_COMMIT_IN_MAIN" "$TMP_DIR/governance_proof_gap_out.txt"; then
  GOVERNANCE_PROOF_GAP_BLOCKED="true"
fi
print_result_block "governance_bypass/proof_gap" "$GOVERNANCE_PROOF_GAP_ATTEMPT" "$GOVERNANCE_PROOF_GAP_BLOCKED"

GOVERNANCE_CHECK_GAP_ATTEMPT="simulate missing required CI checks for HEAD"
GOVERNANCE_CHECK_GAP_BLOCKED="false"
set +e
VERIFY_MAIN_TEST_MODE=true VERIFY_MAIN_PROOF_DIR="$GOVERNANCE_PROOF_DIR" \
VERIFY_MAIN_SKIP_PROOF_VERIFICATION=true \
VERIFY_MAIN_CHECKS_JSON='{"check_runs":[]}' \
bash "$REPO_ROOT/scripts/verify/verify_main_integrity.sh" > "$TMP_DIR/governance_check_gap_out.txt" 2>&1
GOVERNANCE_CHECK_GAP_RC=$?
set -e
if [[ "$GOVERNANCE_CHECK_GAP_RC" -ne 0 ]] && grep -Eq "required check run missing on HEAD|\[FAIL\] MAIN_INTEGRITY" "$TMP_DIR/governance_check_gap_out.txt"; then
  GOVERNANCE_CHECK_GAP_BLOCKED="true"
fi
print_result_block "governance_bypass/check_gap" "$GOVERNANCE_CHECK_GAP_ATTEMPT" "$GOVERNANCE_CHECK_GAP_BLOCKED"

CORRUPTED_CA_ATTEMPT="inject corrupted webhook CA and enforce integrity verifier"
kubectl get mutatingwebhookconfiguration istio-sidecar-injector -o yaml >"$TMP_DIR/original_mutating_webhook.yaml" 2>/dev/null || true
set +e
kubectl get mutatingwebhookconfiguration istio-sidecar-injector -o json \
  | jq '.webhooks[0].clientConfig.caBundle = "aW52YWxpZC1jYS1ieXRlcw=="' \
  | kubectl apply -f - >/dev/null 2>&1
CORRUPTED_CA_APPLY_RC=$?
bash "$REPO_ROOT/scripts/verify/verify_webhook_ca_integrity.sh" >/tmp/break_corrupt_ca.out 2>&1
CORRUPTED_CA_VERIFY_RC=$?
kubectl apply -f "$TMP_DIR/original_mutating_webhook.yaml" >/dev/null 2>&1 || true
set -e
CORRUPTED_CA_DENIED="false"
if [[ "$CORRUPTED_CA_APPLY_RC" -ne 0 || "$CORRUPTED_CA_VERIFY_RC" -ne 0 ]]; then
  CORRUPTED_CA_DENIED="true"
fi
print_denied_block "corrupted_ca_injection" "$CORRUPTED_CA_ATTEMPT" "$CORRUPTED_CA_DENIED"

FAKE_SPIFFE_ATTEMPT="inject fake SPIFFE identity header to bypass identity"
set +e
if [[ -n "$ACTIVE_TEST_CLIENT_POD" ]]; then
  kubectl exec -n threadforge-test -c test-client "$ACTIVE_TEST_CLIENT_POD" -- \
    sh -c 'curl -sS --max-time 10 -o /tmp/fake_spiffe.out -w "%{http_code}" -H "x-forwarded-client-cert: By=spiffe://identity.threadforge.local/ns/threadforge-test/sa/fake" http://echo.threadforge-test.svc.cluster.local/' \
    >"$TMP_DIR/fake_spiffe_code.txt" 2>/dev/null
  FAKE_SPIFFE_CODE="$(cat "$TMP_DIR/fake_spiffe_code.txt" 2>/dev/null || echo 000)"
else
  FAKE_SPIFFE_CODE="000"
fi
set -e
FAKE_SPIFFE_DENIED="false"
if [[ "$FAKE_SPIFFE_CODE" == "403" || "$FAKE_SPIFFE_CODE" == "401" || "$FAKE_SPIFFE_CODE" == "000" ]]; then
  FAKE_SPIFFE_DENIED="true"
fi
print_denied_block "fake_spiffe_identity_injection" "$FAKE_SPIFFE_ATTEMPT" "$FAKE_SPIFFE_DENIED"

POLICY_BLOCKED_ATTEMPT="attempt traffic path declared blocked by policy"
set +e
if [[ -n "$ACTIVE_TEST_CLIENT_POD" ]]; then
  kubectl exec -n threadforge-test -c test-client "$ACTIVE_TEST_CLIENT_POD" -- \
    sh -c 'curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://prometheus.observability.svc.cluster.local:9090/-/ready' \
    >"$TMP_DIR/policy_blocked_code.txt" 2>/dev/null
  POLICY_BLOCKED_CODE="$(cat "$TMP_DIR/policy_blocked_code.txt" 2>/dev/null || echo 000)"
else
  POLICY_BLOCKED_CODE="000"
fi
set -e
POLICY_BLOCKED_DENIED="false"
if [[ "$POLICY_BLOCKED_CODE" == "403" || "$POLICY_BLOCKED_CODE" == "401" || "$POLICY_BLOCKED_CODE" == "000" ]]; then
  POLICY_BLOCKED_DENIED="true"
fi
print_denied_block "policy_claimed_blocked_traffic" "$POLICY_BLOCKED_ATTEMPT" "$POLICY_BLOCKED_DENIED"

NO_SIGNAL_ATTEMPT="send traffic without trace/log emission via sidecar opt-out"
set +e
cat <<EOF | kubectl apply -f - >"$TMP_DIR/no_signal_apply.txt" 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: break-no-signal
  namespace: observability
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  restartPolicy: Never
  containers:
    - name: app
      image: ${TEST_IMAGE}
      command: ["sh", "-ec", "wget -qO- http://tempo.observability.svc.cluster.local:3100/metrics >/dev/null 2>&1 || true; sleep 3"]
EOF
NO_SIGNAL_APPLY_RC=$?
kubectl -n observability delete pod break-no-signal --ignore-not-found >/dev/null 2>&1 || true
set -e
NO_SIGNAL_DENIED="false"
if [[ "$NO_SIGNAL_APPLY_RC" -ne 0 ]]; then
  NO_SIGNAL_DENIED="true"
fi
print_denied_block "traffic_without_trace_log_emission" "$NO_SIGNAL_ATTEMPT" "$NO_SIGNAL_DENIED"

# ── Tempo SPIRE entry deletion: bootstrap guard must fail before deploy ───────
TEMPO_ENTRY_DELETE_ATTEMPT="delete SPIRE entry for Tempo and run bootstrap identity guard before deploy"
TEMPO_EXPECTED_SPIFFE="spiffe://${SPIFFE_TRUST_DOMAIN:-identity.threadforge.local}/ns/observability/sa/tempo-sa"
TEMPO_ENTRY_BREAK_DENIED="false"
set +e
# Find and delete the SPIRE registration entry for Tempo.
TEMPO_ENTRY_ID="$(kubectl exec -n spire-system spire-server-0 -- \
  /opt/spire/bin/spire-server entry show \
  -spiffeID "${TEMPO_EXPECTED_SPIFFE}" \
  -socketPath /run/spire/private/spire-server.sock 2>/dev/null \
  | awk '/Entry ID/{print $NF}' | head -1 || true)"
if [[ -n "$TEMPO_ENTRY_ID" ]]; then
  kubectl exec -n spire-system spire-server-0 -- \
    /opt/spire/bin/spire-server entry delete \
    -entryID "${TEMPO_ENTRY_ID}" \
    -socketPath /run/spire/private/spire-server.sock >/dev/null 2>&1 || true
  TEMPO_ENTRY_DELETED="true"
fi
# Attempt identity preflight used by bootstrap; this must fail immediately.
SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN:-identity.threadforge.local}" \
  bash "$REPO_ROOT/scripts/infra/reconcile_observability_spire_entries.sh" --check >"$TMP_DIR/tempo_identity_break_out.txt" 2>&1
TEMPO_VERIFY_RC=$?
set -e
if [[ "$TEMPO_VERIFY_RC" -ne 0 ]] && grep -q 'SPIRE_ENTRY_MISSING' "$TMP_DIR/tempo_identity_break_out.txt"; then
  TEMPO_ENTRY_BREAK_DENIED="true"
fi
print_denied_block "tempo_spire_entry_deletion" "$TEMPO_ENTRY_DELETE_ATTEMPT" "$TEMPO_ENTRY_BREAK_DENIED"

if [[ "$FAILURES" -ne 0 ]]; then
  echo "[FAIL] ${FAILURES} break tests were ALLOWED"
  exit 2
fi

echo "[PASS] all break-system attacks were blocked by live enforcement"
