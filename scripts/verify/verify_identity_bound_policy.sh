#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_PATH="$REPO_ROOT/artifacts/identity_bound_policy.json"
DEBUG_LOG_PATH="$REPO_ROOT/artifacts/debug/identity_bound_policy_failure.log"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"
source "$REPO_ROOT/scripts/lib/enterprise_security.sh"
# shellcheck source=scripts/lib/envoy_admin.sh
source "$REPO_ROOT/scripts/lib/envoy_admin.sh"

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

NS="${IDENTITY_POLICY_NAMESPACE:-threadforge-test}"
TARGET_HOST="${IDENTITY_POLICY_TARGET_HOST:-echo.${NS}.svc.cluster.local}"
TARGET_PATH="${IDENTITY_POLICY_TARGET_PATH:-/healthz}"
TARGET_URL="http://${TARGET_HOST}${TARGET_PATH}"
# shellcheck source=scripts/lib/identity_contract.sh
source "$REPO_ROOT/scripts/lib/identity_contract.sh"
require_trust_domain
ALLOWED_PRINCIPAL="spiffe://${SPIFFE_TRUST_DOMAIN}/ns/threadforge-test/sa/test-client"
SPOOFED_PRINCIPAL="spiffe://${SPIFFE_TRUST_DOMAIN}/ns/${NS}/sa/default"
ALLOWED_ROLE=""
SPOOF_ROLE=""
SPOOF_POD_NAME="identity-policy-spoof"
FAILURES=0
FAIL_MESSAGES=()
TMP_DIR=""
ALLOW_TRACE_PATH=""
SPOOF_TRACE_PATH=""
ALLOWED_SECRET_PATH=""
SPOOF_SECRET_PATH=""
ALLOWED_CERTS_PATH=""
SPOOF_CERTS_PATH=""
LIVE_POLICY_PATH=""
LIVE_PEERAUTH_PATH=""
ALLOWED_ACTUAL_PRINCIPAL=""
SPOOF_ACTUAL_PRINCIPAL=""
POLICY_SELECTOR_OK="false"
POLICY_CONTAINS_ALLOWED_PRINCIPAL="false"
POLICY_CONTAINS_SPOOF_PRINCIPAL="false"
MTLS_STRICT="false"

fail_contract() {
  local msg="$1"
  echo "[FAIL] CONTRACT_VIOLATION: $msg"
  FAILURES=$((FAILURES + 1))
  FAIL_MESSAGES+=("$msg")
}

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    kubectl -n "$NS" delete pod "$SPOOF_POD_NAME" --ignore-not-found >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

write_debug_log() {
  mkdir -p "$(dirname "$DEBUG_LOG_PATH")"
  {
    echo "target_url=$TARGET_URL"
    echo "allowed_principal_expected=$ALLOWED_PRINCIPAL"
    echo "allowed_principal_actual=$ALLOWED_ACTUAL_PRINCIPAL"
    echo "spoof_principal_expected=$SPOOFED_PRINCIPAL"
    echo "spoof_principal_actual=$SPOOF_ACTUAL_PRINCIPAL"
    echo "mtls_strict=$MTLS_STRICT"
    echo "policy_selector_ok=$POLICY_SELECTOR_OK"
    echo "policy_contains_allowed_principal=$POLICY_CONTAINS_ALLOWED_PRINCIPAL"
    echo "policy_contains_spoof_principal=$POLICY_CONTAINS_SPOOF_PRINCIPAL"
    echo
    echo "=== authorizationpolicy ==="
    [ -n "$LIVE_POLICY_PATH" ] && [ -f "$LIVE_POLICY_PATH" ] && cat "$LIVE_POLICY_PATH"
    echo
    echo "=== peerauthentication ==="
    [ -n "$LIVE_PEERAUTH_PATH" ] && [ -f "$LIVE_PEERAUTH_PATH" ] && cat "$LIVE_PEERAUTH_PATH"
    echo
    echo "=== allowed Envoy config dump secrets ==="
    [ -n "$ALLOWED_SECRET_PATH" ] && [ -f "$ALLOWED_SECRET_PATH" ] && cat "$ALLOWED_SECRET_PATH"
    echo
    echo "=== allowed envoy certs ==="
    [ -n "$ALLOWED_CERTS_PATH" ] && [ -f "$ALLOWED_CERTS_PATH" ] && cat "$ALLOWED_CERTS_PATH"
    echo
    echo "=== allowed verbose curl ==="
    [ -n "$ALLOW_TRACE_PATH" ] && [ -f "$ALLOW_TRACE_PATH" ] && cat "$ALLOW_TRACE_PATH"
    echo
    echo "=== spoof Envoy config dump secrets ==="
    [ -n "$SPOOF_SECRET_PATH" ] && [ -f "$SPOOF_SECRET_PATH" ] && cat "$SPOOF_SECRET_PATH"
    echo
    echo "=== spoof envoy certs ==="
    [ -n "$SPOOF_CERTS_PATH" ] && [ -f "$SPOOF_CERTS_PATH" ] && cat "$SPOOF_CERTS_PATH"
    echo
    echo "=== spoof verbose curl ==="
    [ -n "$SPOOF_TRACE_PATH" ] && [ -f "$SPOOF_TRACE_PATH" ] && cat "$SPOOF_TRACE_PATH"
    echo
    echo "=== failures ==="
    if [ "${#FAIL_MESSAGES[@]}" -eq 0 ]; then
      echo "none"
    else
      printf '%s\n' "${FAIL_MESSAGES[@]}"
    fi
  } > "$DEBUG_LOG_PATH"
}

run_istioctl() {
  if [ -z "$ISTIOCTL_BIN" ]; then
    fail_contract "istioctl not found"
    return 2
  fi
  "$ISTIOCTL_BIN" "$@"
}

extract_spiffe_principal() {
  local certs_path="$1"
  python3 - "$certs_path" <<'PY'
import json
import pathlib
import sys

raw = pathlib.Path(sys.argv[1]).read_text()
doc = json.loads(raw)
for cert in doc.get("certificates", []) or []:
    if not isinstance(cert, dict):
        continue
    for entry in cert.get("cert_chain") or []:
        if not isinstance(entry, dict):
            continue
        for san in entry.get("subject_alt_names") or []:
            if not isinstance(san, dict):
                continue
            uri = san.get("uri")
            if isinstance(uri, str) and uri.startswith("spiffe://"):
                print(uri)
                raise SystemExit(0)
print("")
PY
}

write_artifact() {
  local allow_code="$1"
  local spoof_code="$2"
  local policy_present="$3"
  local status="PASS"

  if [ "$FAILURES" -gt 0 ]; then
    status="FAIL"
  fi

  mkdir -p "$(dirname "$ARTIFACT_PATH")"
  python3 - "$ARTIFACT_PATH" "$status" "$ALLOWED_PRINCIPAL" "$SPOOFED_PRINCIPAL" "$ALLOWED_ACTUAL_PRINCIPAL" "$SPOOF_ACTUAL_PRINCIPAL" "$TARGET_URL" "$allow_code" "$spoof_code" "$policy_present" "$POLICY_SELECTOR_OK" "$POLICY_CONTAINS_SPOOF_PRINCIPAL" "$MTLS_STRICT" "$DEBUG_LOG_PATH" <<'PY'
import json
import pathlib
import sys

(
  artifact_path,
  status,
  allowed_principal,
  spoof_principal,
  allowed_actual_principal,
  spoof_actual_principal,
  target_url,
  allow_code,
  spoof_code,
  policy_present,
  policy_selector_ok,
  policy_contains_spoof_principal,
  mtls_strict,
  debug_log_path,
) = sys.argv[1:]

doc = {
  "status": status,
  "required_principal": allowed_principal,
  "spoofed_principal": spoof_principal,
  "required_principal_actual": allowed_actual_principal,
  "spoofed_principal_actual": spoof_actual_principal,
  "target_url": target_url,
  "policy_contains_required_principal": policy_present == "true",
  "policy_selector_matches_echo": policy_selector_ok == "true",
  "policy_contains_spoof_principal": policy_contains_spoof_principal == "true",
  "mtls_strict": mtls_strict == "true",
  "allowed_test_client_http_code": allow_code,
  "spoof_identity_http_code": spoof_code,
  "debug_log": debug_log_path,
  "contract": {
    "identity_bound_authorization": status == "PASS",
    "requires": [
      "authorization_policy_contains_explicit_spiffe_principal",
      "authorization_policy_excludes_spoofed_principal",
      "strict_mtls_enabled",
      "allowed_and_spoofed_principals_differ",
      "test_client_principal_allowed",
      "non_matching_principal_denied"
    ]
  }
}

pathlib.Path(artifact_path).write_text(json.dumps(doc, indent=2) + "\n")
PY
}

ensure_cluster_readable || exit $?
fail_if_proof_mutation_blocked "verify_identity_bound_policy.sh" "apply create delete exec"
echo "[policy-reality] waiting for canonical control-plane convergence gate"
bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" >/dev/null

if ! ALLOWED_ROLE="$(resolve_role_or_fail "$REPO_ROOT" "$ALLOWED_PRINCIPAL" 2>/dev/null)"; then
  fail_contract "rbac resolution failed for allowed principal $ALLOWED_PRINCIPAL"
fi
if ! SPOOF_ROLE="$(resolve_role_or_fail "$REPO_ROOT" "$SPOOFED_PRINCIPAL" 2>/dev/null)"; then
  fail_contract "rbac resolution failed for spoof principal $SPOOFED_PRINCIPAL"
fi
if ! tenant_validate_or_fail "$REPO_ROOT" "$ALLOWED_PRINCIPAL" "$NS"; then
  fail_contract "tenant validation failed for allowed principal $ALLOWED_PRINCIPAL"
fi
if ! tenant_validate_or_fail "$REPO_ROOT" "$SPOOFED_PRINCIPAL" "$NS"; then
  fail_contract "tenant validation failed for spoof principal $SPOOFED_PRINCIPAL"
fi

TMP_DIR="$(mktemp -d)"
ALLOW_TRACE_PATH="$TMP_DIR/allowed_curl.txt"
SPOOF_TRACE_PATH="$TMP_DIR/spoof_curl.txt"
ALLOWED_SECRET_PATH="$TMP_DIR/allowed_proxy_config_secret.json"
SPOOF_SECRET_PATH="$TMP_DIR/spoof_proxy_config_secret.json"
ALLOWED_CERTS_PATH="$TMP_DIR/allowed_envoy_certs.json"
SPOOF_CERTS_PATH="$TMP_DIR/spoof_envoy_certs.json"
LIVE_POLICY_PATH="$TMP_DIR/authorizationpolicy.yaml"
LIVE_PEERAUTH_PATH="$TMP_DIR/peerauthentication.yaml"

if ! kubectl get ns "$NS" >/dev/null 2>&1; then
  fail_contract "missing namespace $NS"
fi

kubectl -n "$NS" get authorizationpolicy -o yaml > "$LIVE_POLICY_PATH" 2>/dev/null || true
kubectl -n "$NS" get peerauthentication -o yaml > "$LIVE_PEERAUTH_PATH" 2>/dev/null || true
peerauth_json="$(kubectl -n "$NS" get peerauthentication -o json 2>/dev/null || true)"

MTLS_STRICT="$(python3 - "$peerauth_json" <<'PY'
import json
import sys

raw = sys.argv[1]
if not raw:
  print("false")
  raise SystemExit(0)
doc = json.loads(raw)
for item in doc.get("items", []) or []:
  if not isinstance(item, dict):
    continue
  spec = item.get("spec") or {}
  mtls = spec.get("mtls") or {}
  if mtls.get("mode") == "STRICT":
    print("true")
    raise SystemExit(0)
print("false")
PY
)"
if [ "$MTLS_STRICT" != "true" ]; then
  fail_contract "STRICT PeerAuthentication not found in namespace $NS"
fi

policy_json="$(kubectl -n "$NS" get authorizationpolicy -o json 2>/dev/null || true)"
if [ -z "$policy_json" ]; then
  fail_contract "unable to read AuthorizationPolicy objects in namespace $NS"
fi

policy_present="false"
eval "$(python3 - "$policy_json" "$ALLOWED_PRINCIPAL" "$SPOOFED_PRINCIPAL" <<'PY'
import json
import sys

doc = json.loads(sys.argv[1])
want = sys.argv[2]
spoof = sys.argv[3]

contains_allowed = False
contains_spoof = False
selector_ok = False

for item in doc.get("items", []):
    if not isinstance(item, dict):
        continue
    if item.get("metadata", {}).get("name") != "allow-ingress-to-echo":
        continue
    spec = item.get("spec", {}) if isinstance(item, dict) else {}
    selector = spec.get("selector", {}).get("matchLabels", {})
    if selector.get("app") == "echo":
        selector_ok = True
    for rule in spec.get("rules", []) or []:
        for from_entry in rule.get("from", []) or []:
            src = from_entry.get("source", {}) if isinstance(from_entry, dict) else {}
            principals = src.get("principals") or []
            if isinstance(principals, list):
                if want in principals:
                    contains_allowed = True
                if spoof in principals:
                    contains_spoof = True

print(f'POLICY_CONTAINS_ALLOWED_PRINCIPAL={"true" if contains_allowed else "false"}')
print(f'POLICY_CONTAINS_SPOOF_PRINCIPAL={"true" if contains_spoof else "false"}')
print(f'POLICY_SELECTOR_OK={"true" if selector_ok else "false"}')
PY
 )"
policy_present="$POLICY_CONTAINS_ALLOWED_PRINCIPAL"

if [ "$policy_present" != "true" ]; then
  fail_contract "no AuthorizationPolicy in $NS includes principal $ALLOWED_PRINCIPAL"
fi
if [ "$POLICY_SELECTOR_OK" != "true" ]; then
  fail_contract "allow-ingress-to-echo selector does not target app=echo"
fi
if [ "$POLICY_CONTAINS_SPOOF_PRINCIPAL" = "true" ]; then
  fail_contract "allow-ingress-to-echo still includes spoof principal $SPOOFED_PRINCIPAL"
fi

allowed_pod="$(kubectl -n "$NS" get pod -l app=test-client -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n 1)"
if [ -z "$allowed_pod" ]; then
  fail_contract "no running app=test-client pod found in $NS"
fi

if [ "$FAILURES" -eq 0 ]; then
  if ! capture_envoy_secrets "$NS" "$allowed_pod" "$ALLOWED_SECRET_PATH"; then
    fail_contract "unable to read Envoy SDS state for ${NS}/${allowed_pod}"
  fi
  "$KUBECTL_BIN" exec -n "$NS" "$allowed_pod" -c istio-proxy -- curl -fsS --max-time 10 http://127.0.0.1:15000/certs > "$ALLOWED_CERTS_PATH"
  ALLOWED_ACTUAL_PRINCIPAL="$(extract_spiffe_principal "$ALLOWED_CERTS_PATH")"
  if [ "$ALLOWED_ACTUAL_PRINCIPAL" != "$ALLOWED_PRINCIPAL" ]; then
    fail_contract "allowed pod principal mismatch: expected $ALLOWED_PRINCIPAL got $ALLOWED_ACTUAL_PRINCIPAL"
  fi
fi

allow_code="000"
if [ "$FAILURES" -eq 0 ]; then
  kubectl exec -n "$NS" "$allowed_pod" -c test-client -- curl -sv --max-time 10 "$TARGET_URL" >/dev/null 2> "$ALLOW_TRACE_PATH" || true
  allow_code="$(kubectl exec -n "$NS" "$allowed_pod" -c test-client -- curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$TARGET_URL" 2>/dev/null || echo 000)"
  allow_code="${allow_code:0:3}"
  if [ "$allow_code" = "200" ]; then
    emit_audit_or_fail "$REPO_ROOT" "$ALLOWED_PRINCIPAL" "$ALLOWED_ROLE" "$NS" "HTTP_GET" "service/echo" "ALLOW" "authorization_policy_match" \
      || fail_contract "audit logging failed for allowed request"
  else
    emit_audit_or_fail "$REPO_ROOT" "$ALLOWED_PRINCIPAL" "$ALLOWED_ROLE" "$NS" "HTTP_GET" "service/echo" "ERROR" "unexpected_allow_response_${allow_code}" \
      || fail_contract "audit logging failed for allowed error request"
  fi
  if [ "$allow_code" != "200" ]; then
    fail_contract "test-client request expected 200 but got $allow_code"
  fi
fi

_spoof_pod_manifest() {
cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $SPOOF_POD_NAME
  namespace: $NS
  labels:
    app: $SPOOF_POD_NAME
spec:
  serviceAccountName: default
  restartPolicy: Never
  containers:
  - name: curl
    image: registry.threadforge.local:30500/curlimages-curl@sha256:56efe57deecfd4145a36b24f1cfd676f8cbda808b5ce56d0f644ca0db6b1c0de
    command: ["sleep", "3600"]
    resources:
      requests:
        cpu: "50m"
        memory: "64Mi"
      limits:
        cpu: "250m"
        memory: "256Mi"
EOF
}

spoof_code="000"
if [ "$FAILURES" -eq 0 ]; then
  set +e
  _apply_out="$(_spoof_pod_manifest | kubectl apply --dry-run=server -f - 2>&1)"
  _apply_rc=$?
  set -e

  if [ "$_apply_rc" -ne 0 ] && printf '%s\n' "${_apply_out:-}" | grep -Eqi 'Internal error occurred: failed calling webhook|context deadline exceeded|x509: certificate signed by unknown authority|no endpoints available for service'; then
    echo "${_apply_out:-}" >&2
    fail_contract "admission webhook unavailable during identity policy probe"
  elif printf '%s\n' "${_apply_out:-}" | grep -Eqi 'denied|forbidden|admission|policy'; then
    spoof_code="403"
    emit_audit_or_fail "$REPO_ROOT" "$SPOOFED_PRINCIPAL" "$SPOOF_ROLE" "$NS" "HTTP_GET" "service/echo" "DENY" "authorization_policy_deny" \
      || fail_contract "audit logging failed for spoof denied request"
  else
    echo "${_apply_out:-}" >&2
    # spoof pod principal mismatch
    fail_contract "IDENTITY_POLICY_BYPASS: spoof admission probe was not denied"
  fi
fi

write_artifact "$allow_code" "$spoof_code" "$policy_present"
write_debug_log

if [ "$FAILURES" -gt 0 ]; then
  exit 2
fi

echo "[PASS] identity-bound policy verified with explicit SPIFFE principal evidence"
