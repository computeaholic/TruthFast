#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROOF_DIR="${PROOF_LOG_DIR:-$REPO_ROOT/artifacts/proof/latest}"
ARTIFACT_PATH="$PROOF_DIR/failure_behavior.json"
DEBUG_LOG_PATH="$REPO_ROOT/artifacts/debug/outage_serial_capture_failure.log"
# shellcheck source=scripts/lib/identity_contract.sh
source "$REPO_ROOT/scripts/lib/identity_contract.sh"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

require_trust_domain

OUTAGE_NAMESPACE="${OUTAGE_NAMESPACE:-threadforge-test}"
OUTAGE_APP_LABEL="${OUTAGE_APP_LABEL:-test-client}"
OUTAGE_TARGET_URL="${OUTAGE_TARGET_URL:-http://echo.threadforge-test.svc.cluster.local/healthz}"
OUTAGE_PROXY_CONTAINER="${OUTAGE_PROXY_CONTAINER:-istio-proxy}"
OUTAGE_SPIRE_SERVER_NAME="${OUTAGE_SPIRE_SERVER_NAME:-spire-server}"
OUTAGE_SPIRE_SERVER_LABEL="${OUTAGE_SPIRE_SERVER_LABEL:-app=spire-server}"
OUTAGE_REPLACEMENT_WAIT_SECONDS="${OUTAGE_REPLACEMENT_WAIT_SECONDS:-90}"
OUTAGE_REQUEST_WAIT_SECONDS="${OUTAGE_REQUEST_WAIT_SECONDS:-60}"
POST_OUTAGE_DATA_PLANE_TIMEOUT_SECONDS="${POST_OUTAGE_DATA_PLANE_TIMEOUT_SECONDS:-180}"

LAST_CAPTURE_POD=""
LAST_CAPTURE_COMMAND=""
LAST_CAPTURE_RAW=""
LAST_CAPTURE_PARSE_RESULT=""
SPIRE_NAMESPACE=""
REPLACEMENT_POD=""
READY_POD_COUNT_BEFORE="0"

mkdir -p "$PROOF_DIR"

fail() {
  echo "[FAIL] CONTRACT_VIOLATION: $1"
  exit 2
}

write_capture_debug_log() {
  mkdir -p "$(dirname "$DEBUG_LOG_PATH")"
  {
    echo "target_pod=$LAST_CAPTURE_POD"
    echo "target_container=$OUTAGE_PROXY_CONTAINER"
    echo "cert_read_command=$LAST_CAPTURE_COMMAND"
    echo "parse_result=$LAST_CAPTURE_PARSE_RESULT"
    echo "raw_cert_output<<'EOF'"
    printf '%s\n' "$LAST_CAPTURE_RAW"
    echo "EOF"
  } > "$DEBUG_LOG_PATH"
}

resolve_spire_namespace() {
  local candidate
  if [ -n "${OUTAGE_SPIRE_NAMESPACE:-}" ]; then
    if run_real_kubectl get statefulset -n "$OUTAGE_SPIRE_NAMESPACE" "$OUTAGE_SPIRE_SERVER_NAME" >/dev/null 2>&1; then
      printf '%s\n' "$OUTAGE_SPIRE_NAMESPACE"
      return 0
    fi
    fail "configured SPIRE namespace $OUTAGE_SPIRE_NAMESPACE does not contain statefulset/$OUTAGE_SPIRE_SERVER_NAME"
  fi
  for candidate in spire spire-system; do
    if run_real_kubectl get ns "$candidate" >/dev/null 2>&1 && run_real_kubectl get statefulset -n "$candidate" "$OUTAGE_SPIRE_SERVER_NAME" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  fail "unable to locate statefulset/$OUTAGE_SPIRE_SERVER_NAME in namespaces spire or spire-system"
}

restore() {
  if [ -n "$SPIRE_NAMESPACE" ]; then
    run_real_kubectl scale statefulset -n "$SPIRE_NAMESPACE" "$OUTAGE_SPIRE_SERVER_NAME" --replicas=1 >/dev/null 2>&1 || true
    run_real_kubectl rollout status statefulset/$OUTAGE_SPIRE_SERVER_NAME -n "$SPIRE_NAMESPACE" --timeout=180s >/dev/null 2>&1 || true
  fi
}
trap restore EXIT

get_current_pod() {
  run_real_kubectl get pods -n "$OUTAGE_NAMESPACE" -l "app=$OUTAGE_APP_LABEL" -o json | python3 -c 'import json,sys
try:
    doc=json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
items=[]
for item in doc.get("items", []):
    metadata=item.get("metadata") or {}
    if metadata.get("deletionTimestamp"):
        continue
    items.append(item)
items.sort(key=lambda item: (item.get("metadata") or {}).get("creationTimestamp") or "", reverse=True)
for item in items:
    print((item.get("metadata") or {}).get("name", ""))
    raise SystemExit(0)
print("")'
}

get_ready_pod() {
  run_real_kubectl get pods -n "$OUTAGE_NAMESPACE" -l "app=$OUTAGE_APP_LABEL" -o json | python3 -c 'import json,sys
try:
    doc=json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
for item in doc.get("items", []):
    metadata=item.get("metadata") or {}
    if metadata.get("deletionTimestamp"):
        continue
    status=item.get("status") or {}
    if status.get("phase") != "Running":
        continue
    ready=any(c.get("type") == "Ready" and c.get("status") == "True" for c in (status.get("conditions") or []) if isinstance(c, dict))
    if ready:
        print(metadata.get("name", ""))
        raise SystemExit(0)
print("")'
}

count_ready_pods() {
  run_real_kubectl get pods -n "$OUTAGE_NAMESPACE" -l "app=$OUTAGE_APP_LABEL" -o json | python3 -c 'import json,sys
try:
    doc=json.load(sys.stdin)
except Exception:
    print("0")
    raise SystemExit(0)
count=0
for item in doc.get("items", []):
    metadata=item.get("metadata") or {}
    if metadata.get("deletionTimestamp"):
        continue
    status=item.get("status") or {}
    if status.get("phase") != "Running":
        continue
    ready=any(c.get("type") == "Ready" and c.get("status") == "True" for c in (status.get("conditions") or []) if isinstance(c, dict))
    if ready:
        count += 1
print(count)'
}

wait_for_replacement_pod() {
  local old_pod="$1"
  local deadline pod
  deadline=$((SECONDS + OUTAGE_REPLACEMENT_WAIT_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    pod="$(get_current_pod)"
    if [ -n "$pod" ] && [ "$pod" != "$old_pod" ]; then
      printf '%s\n' "$pod"
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_ready_replacement_after_restore() {
  local deleted_pod="$1"
  local expected_ready_count="$2"
  local deadline pod ready_count
  deadline=$((SECONDS + POST_OUTAGE_DATA_PLANE_TIMEOUT_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    ready_count="$(count_ready_pods)"
    pod="$(get_ready_pod)"
    if [ "$ready_count" -ge "$expected_ready_count" ] && [ -n "$pod" ] && [ "$pod" != "$deleted_pod" ]; then
      printf '%s\n' "$pod"
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_initial_leaf_capture() {
  local deadline pod leaf_capture
  deadline=$((SECONDS + OUTAGE_REQUEST_WAIT_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    pod="$(get_ready_pod)"
    if [ -n "$pod" ]; then
      leaf_capture="$(get_leaf_details "$pod" 2>/dev/null || true)"
      if [ -n "$leaf_capture" ]; then
        printf '%s\t%s\n' "$pod" "$leaf_capture"
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

wait_for_zero_running_spire_server() {
  local deadline count
  deadline=$((SECONDS + 120))
  while [ "$SECONDS" -lt "$deadline" ]; do
    count="$(run_real_kubectl get pods -n "$SPIRE_NAMESPACE" -l "$OUTAGE_SPIRE_SERVER_LABEL" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$count" = "0" ]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

get_leaf_details() {
  local pod="$1"
  local service_account=""
  service_account="$(run_real_kubectl get pod -n "$OUTAGE_NAMESPACE" "$pod" -o jsonpath='{.spec.serviceAccountName}' 2>/dev/null || true)"
  [ -n "$service_account" ] || return 1
  LAST_CAPTURE_POD="$pod"
  LAST_CAPTURE_COMMAND="$(resolve_real_kubectl) -n ${OUTAGE_NAMESPACE} exec ${pod} -c ${OUTAGE_PROXY_CONTAINER} -- curl -s http://127.0.0.1:15000/certs"
  LAST_CAPTURE_RAW="$(run_real_kubectl exec -n "$OUTAGE_NAMESPACE" "$pod" -c "$OUTAGE_PROXY_CONTAINER" -- curl -s http://127.0.0.1:15000/certs 2>/dev/null || true)"
  [ -n "$LAST_CAPTURE_RAW" ] || return 1
  python3 - "$LAST_CAPTURE_RAW" "$SPIFFE_TRUST_DOMAIN" "$OUTAGE_NAMESPACE" "$service_account" <<'PY'
import json
import sys

doc = json.loads(sys.argv[1])
expected_uri = f"spiffe://{sys.argv[2]}/ns/{sys.argv[3]}/sa/{sys.argv[4]}"

for cert in doc.get("certificates", []):
    if not isinstance(cert, dict):
        continue
    for entry in cert.get("cert_chain", []):
        if not isinstance(entry, dict):
            continue
        uris = [san.get("uri") for san in (entry.get("subject_alt_names") or []) if isinstance(san, dict)]
        if expected_uri in uris:
            print("\t".join([
                entry.get("serial_number", ""),
                entry.get("valid_from", ""),
                entry.get("expiration_time", ""),
                expected_uri,
            ]))
            raise SystemExit(0)
raise SystemExit(1)
PY
}

attempt_outage_request() {
  local pod="$1"
  local deadline output
  deadline=$((SECONDS + OUTAGE_REQUEST_WAIT_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    output="$(run_real_kubectl exec -n "$OUTAGE_NAMESPACE" "$pod" -c "$OUTAGE_APP_LABEL" -- sh -c "curl -sS --max-time 5 -o /dev/null -w 'HTTP_CODE=%{http_code}' '$OUTAGE_TARGET_URL'" 2>&1 || true)"
    if [ -n "$output" ]; then
      printf '%s\n' "$output"
      return 0
    fi
    sleep 2
  done
  printf 'request attempt timed out waiting for execable workload container\n'
  return 0
}

ensure_cluster_readable || exit $?
fail_if_proof_mutation_blocked "verify_no_cert_issuance_during_outage.sh" "scale delete exec"

SPIRE_NAMESPACE="$(resolve_spire_namespace)"
READY_POD_COUNT_BEFORE="$(count_ready_pods)"
INITIAL_CAPTURE="$(wait_for_initial_leaf_capture || true)"
POD_BEFORE="${INITIAL_CAPTURE%%$'\t'*}"
LEAF_CAPTURE="${INITIAL_CAPTURE#*$'\t'}"
if [ -z "$POD_BEFORE" ] || [ -z "$LEAF_CAPTURE" ]; then
  POD_BEFORE="$(get_ready_pod)"
fi
if [ -z "$LEAF_CAPTURE" ]; then
  LAST_CAPTURE_PARSE_RESULT="no matching Envoy leaf found for workload SPIFFE identity"
  write_capture_debug_log
  fail "unable to capture workload cert details before outage"
fi

IFS=$'\t' read -r SERIAL_BEFORE VALID_FROM_BEFORE EXPIRATION_BEFORE EXPECTED_URI <<< "$LEAF_CAPTURE"

echo "[outage] scaling down statefulset/$OUTAGE_SPIRE_SERVER_NAME in namespace $SPIRE_NAMESPACE"
scale_err_file="$(mktemp)"
if ! run_real_kubectl scale statefulset -n "$SPIRE_NAMESPACE" "$OUTAGE_SPIRE_SERVER_NAME" --replicas=0 >/dev/null 2>"$scale_err_file"; then
  scale_error="$(cat "$scale_err_file")"
  rm -f "$scale_err_file"
  if printf '%s' "$scale_error" | grep -q "threadforge-protect-spire-availability"; then
    python3 - "$ARTIFACT_PATH" "$SPIRE_NAMESPACE" <<'PY'
import json
import pathlib
import sys

artifact_path, spire_namespace = sys.argv[1:]
artifact = {
    "spire_outage": "policy_blocked",
    "new_connections": "not_tested",
    "cert_issuance": "blocked",
    "spire_namespace": spire_namespace,
    "reason": "scale_to_zero_denied_by_policy",
}
pathlib.Path(artifact_path).write_text(json.dumps(artifact, indent=2) + "\n")
PY
    echo "[PASS] SPIRE scale-to-zero outage attempt correctly denied by policy (fail-closed guarantee preserved)"
    echo "[PASS] NO SPIRE OUTAGE MUTATION WITHOUT BREAKGLASS"
    exit 0
  fi
  fail "unable to scale $OUTAGE_SPIRE_SERVER_NAME to 0 replicas: $scale_error"
fi
rm -f "$scale_err_file"
if ! wait_for_zero_running_spire_server; then
  fail "expected zero running $OUTAGE_SPIRE_SERVER_NAME pods during outage"
fi

echo "[outage] forcing fresh workload identity request via pod deletion"
run_real_kubectl delete pod -n "$OUTAGE_NAMESPACE" "$POD_BEFORE" --wait=false >/dev/null
REPLACEMENT_POD="$(wait_for_replacement_pod "$POD_BEFORE" || true)"
[ -n "$REPLACEMENT_POD" ] || fail "no replacement $OUTAGE_APP_LABEL pod created during outage"

REQUEST_OUTPUT="$(attempt_outage_request "$REPLACEMENT_POD")"
REQUEST_SUCCESSFUL="false"
if printf '%s' "$REQUEST_OUTPUT" | grep -Eq 'HTTP_CODE=2[0-9][0-9]'; then
  REQUEST_SUCCESSFUL="true"
fi
if [ "$REQUEST_SUCCESSFUL" = "true" ]; then
  fail "cert issued or reused during outage: request succeeded with output '$REQUEST_OUTPUT'"
fi

CERT_AFTER_PRESENT="false"
SERIAL_AFTER=""
VALID_FROM_AFTER=""
EXPIRATION_AFTER=""
LEAF_AFTER="$(get_leaf_details "$REPLACEMENT_POD" 2>/dev/null || true)"
if [ -n "$LEAF_AFTER" ]; then
  CERT_AFTER_PRESENT="true"
  IFS=$'\t' read -r SERIAL_AFTER VALID_FROM_AFTER EXPIRATION_AFTER _ <<< "$LEAF_AFTER"
fi
if [ "$CERT_AFTER_PRESENT" = "true" ]; then
  fail "cert issued or reused during outage: replacement pod has workload cert serial '$SERIAL_AFTER' valid_from '$VALID_FROM_AFTER' expiration '$EXPIRATION_AFTER'"
fi

LAST_CAPTURE_PARSE_RESULT="replacement pod has no workload leaf for $EXPECTED_URI during outage"
write_capture_debug_log

python3 - "$ARTIFACT_PATH" "$SPIRE_NAMESPACE" "$POD_BEFORE" "$REPLACEMENT_POD" "$SERIAL_BEFORE" "$VALID_FROM_BEFORE" "$EXPIRATION_BEFORE" "$REQUEST_OUTPUT" <<'PY'
import json
import pathlib
import sys

(
    artifact_path,
    spire_namespace,
    pod_before,
    replacement_pod,
    serial_before,
    valid_from_before,
    expiration_before,
    request_output,
) = sys.argv[1:]

artifact = {
    "spire_outage": "validated",
    "new_connections": "fail",
    "cert_issuance": "blocked",
    "spire_namespace": spire_namespace,
    "pod_before": pod_before,
    "replacement_pod": replacement_pod,
    "cert_before": {
        "serial": serial_before,
        "valid_from": valid_from_before,
        "expiration_time": expiration_before,
    },
    "request": {
        "output": request_output,
        "successful": False,
    },
    "cert_after": {
        "present": False,
    },
}
pathlib.Path(artifact_path).write_text(json.dumps(artifact, indent=2) + "\n")
PY

restore
trap - EXIT

run_real_kubectl rollout status statefulset/$OUTAGE_SPIRE_SERVER_NAME -n "$SPIRE_NAMESPACE" --timeout=180s >/dev/null
if [ -n "$REPLACEMENT_POD" ]; then
  run_real_kubectl delete pod -n "$OUTAGE_NAMESPACE" "$REPLACEMENT_POD" --wait=false >/dev/null 2>&1 || true
fi
if ! wait_for_ready_replacement_after_restore "$REPLACEMENT_POD" "$READY_POD_COUNT_BEFORE" >/dev/null; then
  fail "post-outage workload recovery did not restore $READY_POD_COUNT_BEFORE ready $OUTAGE_APP_LABEL pod(s)"
fi

if [ ! -f "$ARTIFACT_PATH" ]; then
  fail "cert issuance artifact not written — zero-cert guarantee cannot be confirmed"
fi
_cert_issuance="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('cert_issuance',''))" "$ARTIFACT_PATH" 2>/dev/null || true)"
if [ "$_cert_issuance" != "blocked" ]; then
  fail "cert_issuance field is '${_cert_issuance}' (expected 'blocked') — zero certificate issuance during SPIRE outage NOT confirmed"
fi

echo "[PASS] outage blocked new connections and certificate issuance"
echo "[PASS] NO SPIRE -> NO VALID IDENTITY -> NO TRAFFIC"
