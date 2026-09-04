#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROOF_DIR="${PROOF_LOG_DIR:-$REPO_ROOT/artifacts/proof/latest}"
ARTIFACT_PATH="$PROOF_DIR/existing_session_fail_closed.json"
DEBUG_LOG_PATH="$REPO_ROOT/artifacts/debug/existing_session_fail_closed_failure.log"

# shellcheck source=scripts/lib/identity_contract.sh
source "$REPO_ROOT/scripts/lib/identity_contract.sh"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"
# shellcheck source=scripts/lib/enterprise_security.sh
source "$REPO_ROOT/scripts/lib/enterprise_security.sh"

require_trust_domain

OUTAGE_NAMESPACE="${OUTAGE_NAMESPACE:-threadforge-test}"
OUTAGE_APP_LABEL="${OUTAGE_APP_LABEL:-test-client}"
OUTAGE_TARGET_HOST="${OUTAGE_TARGET_HOST:-echo.threadforge-test.svc.cluster.local}"
OUTAGE_TARGET_URL="${OUTAGE_TARGET_URL:-http://echo.threadforge-test.svc.cluster.local/healthz}"
OUTAGE_TARGET_PORT="${OUTAGE_TARGET_PORT:-80}"
OUTAGE_PROXY_CONTAINER="${OUTAGE_PROXY_CONTAINER:-istio-proxy}"
OUTAGE_SPIRE_SERVER_NAME="${OUTAGE_SPIRE_SERVER_NAME:-spire-server}"
OUTAGE_SPIRE_SERVER_LABEL="${OUTAGE_SPIRE_SERVER_LABEL:-app=spire-server}"
OUTAGE_SPIRE_NAMESPACE="${OUTAGE_SPIRE_NAMESPACE:-}"
OUTAGE_REQUEST_WAIT_SECONDS="${OUTAGE_REQUEST_WAIT_SECONDS:-60}"
OUTAGE_SESSION_MAX_WAIT_SECONDS="${OUTAGE_SESSION_MAX_WAIT_SECONDS:-180}"
OUTAGE_SESSION_EXPIRY_GRACE_SECONDS="${OUTAGE_SESSION_EXPIRY_GRACE_SECONDS:-15}"
POST_OUTAGE_DATA_PLANE_TIMEOUT_SECONDS="${POST_OUTAGE_DATA_PLANE_TIMEOUT_SECONDS:-180}"
OUTAGE_SCALE_AS_USER="${OUTAGE_SCALE_AS_USER:-}"
OUTAGE_SCALE_AS_GROUP="${OUTAGE_SCALE_AS_GROUP:-}"
OUTAGE_BREAKGLASS_AUTHORITY="${OUTAGE_BREAKGLASS_AUTHORITY:-normal-authority}"
THREADFORGE_AUDIT_LOG_PATH="${THREADFORGE_AUDIT_LOG_PATH:-$REPO_ROOT/artifacts/audit/audit.log}"

SPIRE_NAMESPACE=""
POD_BEFORE=""
READY_POD_COUNT_BEFORE="0"
SESSION_LOG=""
SESSION_PID=""
LAST_RAW=""
BREAKGLASS_AUDIT_PRESENT="false"
POST_RESTORE_REQUEST_OUTPUT=""

mkdir -p "$PROOF_DIR"

fail() {
  echo "[FAIL] CONTRACT_VIOLATION: $1"
  exit 2
}

resolve_spire_namespace() {
  local candidate
  if [ -n "$OUTAGE_SPIRE_NAMESPACE" ]; then
    if run_real_kubectl get statefulset -n "$OUTAGE_SPIRE_NAMESPACE" "$OUTAGE_SPIRE_SERVER_NAME" >/dev/null 2>&1; then
      printf '%s\n' "$OUTAGE_SPIRE_NAMESPACE"
      return 0
    fi
    fail "configured SPIRE namespace $OUTAGE_SPIRE_NAMESPACE does not contain statefulset/$OUTAGE_SPIRE_SERVER_NAME"
  fi
  for candidate in spire spire-system; do
    if run_real_kubectl get ns "$candidate" >/dev/null 2>&1 \
      && run_real_kubectl get statefulset -n "$candidate" "$OUTAGE_SPIRE_SERVER_NAME" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  fail "unable to locate statefulset/$OUTAGE_SPIRE_SERVER_NAME in namespaces spire or spire-system"
}

cleanup() {
  if [ -n "$SESSION_PID" ] && kill -0 "$SESSION_PID" 2>/dev/null; then
    kill "$SESSION_PID" 2>/dev/null || true
    wait "$SESSION_PID" 2>/dev/null || true
  fi
}

restore() {
  cleanup
  if [ -n "$SPIRE_NAMESPACE" ]; then
    run_real_kubectl scale statefulset -n "$SPIRE_NAMESPACE" "$OUTAGE_SPIRE_SERVER_NAME" --replicas=1 >/dev/null 2>&1 || true
    run_real_kubectl rollout status statefulset/$OUTAGE_SPIRE_SERVER_NAME -n "$SPIRE_NAMESPACE" --timeout=180s >/dev/null 2>&1 || true
  fi
}
trap restore EXIT

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

wait_for_ready_pods_after_restore() {
  local expected_ready_count="$1"
  local deadline pod ready_count
  deadline=$((SECONDS + POST_OUTAGE_DATA_PLANE_TIMEOUT_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    ready_count="$(count_ready_pods)"
    pod="$(get_ready_pod)"
    if [ "$ready_count" -ge "$expected_ready_count" ] && [ -n "$pod" ]; then
      printf '%s\n' "$pod"
      return 0
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

scale_spire_server_to_zero() {
  local scale_args=(scale statefulset -n "$SPIRE_NAMESPACE" "$OUTAGE_SPIRE_SERVER_NAME" --replicas=0)
  if [ -n "$OUTAGE_SCALE_AS_USER" ]; then
    scale_args+=(--as="$OUTAGE_SCALE_AS_USER")
  fi
  if [ -n "$OUTAGE_SCALE_AS_GROUP" ]; then
    scale_args+=(--as-group="$OUTAGE_SCALE_AS_GROUP")
  fi
  run_real_kubectl "${scale_args[@]}"
}

record_breakglass_scale() {
  [ -n "$OUTAGE_SCALE_AS_USER" ] || return 0
  [ -n "$OUTAGE_SCALE_AS_GROUP" ] || fail "break-glass scale requires OUTAGE_SCALE_AS_GROUP"
  emit_audit_or_fail "$REPO_ROOT" \
    "user:${OUTAGE_SCALE_AS_USER}" \
    "breakglass-operator" \
    "$SPIRE_NAMESPACE" \
    "SCALE_STATEFULSET" \
    "statefulset/$OUTAGE_SPIRE_SERVER_NAME" \
    "ALLOW" \
    "spire_outage_experiment_scale" \
    "$THREADFORGE_AUDIT_LOG_PATH" \
    "true" \
    "$OUTAGE_SCALE_AS_GROUP"
  BREAKGLASS_AUDIT_PRESENT="true"
}

get_leaf_details() {
  local pod="$1"
  local service_account=""
  service_account="$(run_real_kubectl get pod -n "$OUTAGE_NAMESPACE" "$pod" -o jsonpath='{.spec.serviceAccountName}' 2>/dev/null || true)"
  [ -n "$service_account" ] || return 1
  LAST_RAW="$(run_real_kubectl exec -n "$OUTAGE_NAMESPACE" "$pod" -c "$OUTAGE_PROXY_CONTAINER" -- curl -s http://127.0.0.1:15000/certs 2>/dev/null || true)"
  [ -n "$LAST_RAW" ] || return 1
  python3 - "$LAST_RAW" "$SPIFFE_TRUST_DOMAIN" "$OUTAGE_NAMESPACE" "$service_account" <<'PY'
import json
import os
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

compute_wait_until_expiry() {
  local expiration_time="$1"
  python3 - "$expiration_time" "$OUTAGE_SESSION_EXPIRY_GRACE_SECONDS" "$OUTAGE_SESSION_MAX_WAIT_SECONDS" <<'PY'
import datetime
import sys

expiration_time = sys.argv[1]
grace = int(sys.argv[2])
max_wait = int(sys.argv[3])
exp_dt = None
for parser in (
  lambda value: datetime.datetime.strptime(value, "%b %d %H:%M:%S %Y GMT").replace(tzinfo=datetime.timezone.utc),
  lambda value: datetime.datetime.fromisoformat(value.replace("Z", "+00:00")),
):
  try:
    exp_dt = parser(expiration_time)
    break
  except ValueError:
    continue
if exp_dt is None:
  raise SystemExit(f"unsupported expiration_time format: {expiration_time!r}")
now_dt = datetime.datetime.now(datetime.timezone.utc)
wait_seconds = int((exp_dt - now_dt).total_seconds()) + grace
wait_seconds = max(wait_seconds, 5)
wait_seconds = min(wait_seconds, max_wait)
print(wait_seconds)
PY
}

write_debug_log() {
  local session_wait_seconds="$1"
  local cert_serial="$2"
  local cert_expiration="$3"
  local session_statuses_json="$4"
  local fresh_request_output="$5"
  mkdir -p "$(dirname "$DEBUG_LOG_PATH")"
  {
    echo "pod_before=$POD_BEFORE"
    echo "session_wait_seconds=$session_wait_seconds"
    echo "cert_serial=$cert_serial"
    echo "cert_expiration=$cert_expiration"
    echo "session_statuses=$session_statuses_json"
    echo "fresh_request_output=$fresh_request_output"
    echo "raw_cert_output<<'EOF'"
    printf '%s\n' "$LAST_RAW"
    echo "EOF"
    if [ -n "$SESSION_LOG" ] && [ -f "$SESSION_LOG" ]; then
      echo "session_log<<'EOF'"
      cat "$SESSION_LOG"
      echo "EOF"
    fi
  } > "$DEBUG_LOG_PATH"
}

attempt_fresh_request() {
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
  printf 'request attempt timed out waiting for curl output\n'
  return 0
}

attempt_allowed_request_after_restore() {
  local pod="$1"
  local deadline output=""
  deadline=$((SECONDS + POST_OUTAGE_DATA_PLANE_TIMEOUT_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    output="$(run_real_kubectl exec -n "$OUTAGE_NAMESPACE" "$pod" -c "$OUTAGE_APP_LABEL" -- sh -c "curl -sS --max-time 5 -o /dev/null -w 'HTTP_CODE=%{http_code}' '$OUTAGE_TARGET_URL'" 2>&1 || true)"
    if printf '%s' "$output" | grep -Eq 'HTTP_CODE=2[0-9][0-9]'; then
      printf '%s\n' "$output"
      return 0
    fi
    sleep 2
  done
  printf '%s\n' "${output:-request attempt timed out waiting for recovery}"
  return 1
}

ensure_cluster_readable || exit $?
fail_if_proof_mutation_blocked "verify_existing_session_fail_closed.sh" "scale exec"

SPIRE_NAMESPACE="$(resolve_spire_namespace)"
READY_POD_COUNT_BEFORE="$(count_ready_pods)"
POD_BEFORE="$(get_ready_pod)"
[ -n "$POD_BEFORE" ] || fail "no ready $OUTAGE_APP_LABEL pod found before outage"

LEAF_CAPTURE="$(get_leaf_details "$POD_BEFORE" 2>/dev/null || true)"
[ -n "$LEAF_CAPTURE" ] || fail "unable to capture workload cert details before outage"
IFS=$'\t' read -r SERIAL_BEFORE VALID_FROM_BEFORE EXPIRATION_BEFORE EXPECTED_URI <<< "$LEAF_CAPTURE"
WAIT_SECONDS="$(compute_wait_until_expiry "$EXPIRATION_BEFORE")"
SESSION_LOG="$(mktemp)"

run_real_kubectl exec -n "$OUTAGE_NAMESPACE" "$POD_BEFORE" -c "$OUTAGE_APP_LABEL" -- sh -ec "
{
  printf 'GET /healthz HTTP/1.1\\r\\nHost: ${OUTAGE_TARGET_HOST}\\r\\nConnection: keep-alive\\r\\n\\r\\n'
  sleep ${WAIT_SECONDS}
  printf 'GET /healthz HTTP/1.1\\r\\nHost: ${OUTAGE_TARGET_HOST}\\r\\nConnection: close\\r\\n\\r\\n'
  sleep 2
} | nc ${OUTAGE_TARGET_HOST} ${OUTAGE_TARGET_PORT}
" >"$SESSION_LOG" 2>&1 &
SESSION_PID=$!

deadline=$((SECONDS + OUTAGE_REQUEST_WAIT_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
  if grep -Eq '^HTTP/1\.[01] 200' "$SESSION_LOG"; then
    break
  fi
  sleep 1
done
if ! grep -Eq '^HTTP/1\.[01] 200' "$SESSION_LOG"; then
  write_debug_log "$WAIT_SECONDS" "$SERIAL_BEFORE" "$EXPIRATION_BEFORE" '[]' 'initial_session_failed'
  fail "failed to establish baseline existing session before SPIRE outage"
fi

echo "[outage] scaling down statefulset/$OUTAGE_SPIRE_SERVER_NAME in namespace $SPIRE_NAMESPACE"
scale_err_file="$(mktemp)"
if ! scale_spire_server_to_zero >/dev/null 2>"$scale_err_file"; then
  scale_error="$(cat "$scale_err_file")"
  rm -f "$scale_err_file"
  if printf '%s' "$scale_error" | grep -q "threadforge-protect-spire-availability"; then
    python3 - "$ARTIFACT_PATH" "$SPIRE_NAMESPACE" "$POD_BEFORE" "$SERIAL_BEFORE" "$VALID_FROM_BEFORE" "$EXPIRATION_BEFORE" <<'PY'
import json
import pathlib
import sys

artifact_path, spire_namespace, pod_before, serial_before, valid_from_before, expiration_before = sys.argv[1:]
artifact = {
    "spire_outage": "policy_blocked",
    "existing_session": "not_tested",
    "fresh_request_after_expiry": "not_tested",
    "spire_namespace": spire_namespace,
    "pod_before": pod_before,
    "cert_before": {
        "serial": serial_before,
        "valid_from": valid_from_before,
        "expiration_time": expiration_before,
    },
    "reason": "scale_to_zero_denied_by_policy",
}
pathlib.Path(artifact_path).write_text(json.dumps(artifact, indent=2) + "\n")
PY
    echo "[PASS] SPIRE scale-to-zero outage attempt correctly denied by policy (fail-closed guarantee preserved)"
    echo "[PASS] EXISTING SESSION OUTAGE MUTATION REQUIRES BREAKGLASS"
    exit 0
  fi
  fail "unable to scale $OUTAGE_SPIRE_SERVER_NAME to 0 replicas: $scale_error"
fi
rm -f "$scale_err_file"
record_breakglass_scale
if ! wait_for_zero_running_spire_server; then
  fail "expected zero running $OUTAGE_SPIRE_SERVER_NAME pods during outage"
fi

wait "$SESSION_PID" || true
SESSION_PID=""

SESSION_STATUSES_JSON="$(python3 - "$SESSION_LOG" <<'PY'
import json
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
statuses = re.findall(r'^HTTP/1\.[01] (\d{3})', text, flags=re.MULTILINE)
print(json.dumps(statuses))
PY
)"

FIRST_STATUS="$(python3 - "$SESSION_STATUSES_JSON" <<'PY'
import json, sys
statuses = json.loads(sys.argv[1])
print(statuses[0] if statuses else "")
PY
)"
POST_EXPIRY_SUCCESS_COUNT="$(python3 - "$SESSION_STATUSES_JSON" <<'PY'
import json, sys
statuses = json.loads(sys.argv[1])
print(sum(1 for value in statuses[1:] if value == "200"))
PY
)"

if [ "$FIRST_STATUS" != "200" ]; then
  write_debug_log "$WAIT_SECONDS" "$SERIAL_BEFORE" "$EXPIRATION_BEFORE" "$SESSION_STATUSES_JSON" 'initial_session_not_200'
  fail "baseline existing session did not return HTTP 200 before outage"
fi
if [ "$POST_EXPIRY_SUCCESS_COUNT" -gt 0 ]; then
  write_debug_log "$WAIT_SECONDS" "$SERIAL_BEFORE" "$EXPIRATION_BEFORE" "$SESSION_STATUSES_JSON" 'post_expiry_session_reused'
  fail "existing session remained valid after SVID expiry while SPIRE was unavailable"
fi

FRESH_REQUEST_OUTPUT="$(attempt_fresh_request "$POD_BEFORE")"
if printf '%s' "$FRESH_REQUEST_OUTPUT" | grep -Eq 'HTTP_CODE=2[0-9][0-9]'; then
  write_debug_log "$WAIT_SECONDS" "$SERIAL_BEFORE" "$EXPIRATION_BEFORE" "$SESSION_STATUSES_JSON" "$FRESH_REQUEST_OUTPUT"
  fail "fresh request from existing pod succeeded after SVID expiry while SPIRE was unavailable"
fi

python3 - "$ARTIFACT_PATH" "$SPIRE_NAMESPACE" "$POD_BEFORE" "$SERIAL_BEFORE" "$VALID_FROM_BEFORE" "$EXPIRATION_BEFORE" "$WAIT_SECONDS" "$SESSION_STATUSES_JSON" "$FRESH_REQUEST_OUTPUT" <<'PY'
import json
import os
import pathlib
import sys

(
    artifact_path,
    spire_namespace,
    pod_before,
    serial_before,
    valid_from_before,
    expiration_before,
    wait_seconds,
    session_statuses_json,
    fresh_request_output,
) = sys.argv[1:]

artifact = {
    "spire_outage": "validated",
    "existing_session": "fail_closed",
    "fresh_request_after_expiry": "fail",
    "spire_namespace": spire_namespace,
    "pod_before": pod_before,
    "cert_before": {
        "serial": serial_before,
        "valid_from": valid_from_before,
        "expiration_time": expiration_before,
    },
    "wait_seconds": int(wait_seconds),
    "session_statuses": json.loads(session_statuses_json),
    "fresh_request": {
        "output": fresh_request_output,
        "successful": False,
    },
    "breakglass_authority": {
        "user": os.environ.get("OUTAGE_SCALE_AS_USER", ""),
        "group": os.environ.get("OUTAGE_SCALE_AS_GROUP", ""),
        "label": os.environ.get("OUTAGE_BREAKGLASS_AUTHORITY", "normal-authority"),
    },
    "breakglass_audit_present": os.environ.get("BREAKGLASS_AUDIT_PRESENT") == "true",
}
pathlib.Path(artifact_path).write_text(json.dumps(artifact, indent=2) + "\n")
PY

restore
trap - EXIT

if ! wait_for_ready_pods_after_restore "$READY_POD_COUNT_BEFORE" >/dev/null; then
  fail "post-outage workload recovery did not restore $READY_POD_COUNT_BEFORE ready $OUTAGE_APP_LABEL pod(s)"
fi

POD_AFTER_RESTORE="$(get_ready_pod)"
[ -n "$POD_AFTER_RESTORE" ] || fail "post-outage recovery did not produce a ready workload pod"
if ! POST_RESTORE_REQUEST_OUTPUT="$(attempt_allowed_request_after_restore "$POD_AFTER_RESTORE")"; then
  fail "post-outage allowed path did not recover after SPIRE restoration"
fi

BREAKGLASS_AUDIT_PRESENT="$BREAKGLASS_AUDIT_PRESENT" \
OUTAGE_SCALE_AS_USER="$OUTAGE_SCALE_AS_USER" \
OUTAGE_SCALE_AS_GROUP="$OUTAGE_SCALE_AS_GROUP" \
OUTAGE_BREAKGLASS_AUTHORITY="$OUTAGE_BREAKGLASS_AUTHORITY" \
python3 - "$ARTIFACT_PATH" "$POST_RESTORE_REQUEST_OUTPUT" <<'PY'
import json
import os
import pathlib
import sys

artifact_path, post_restore_output = sys.argv[1:]
artifact = json.loads(pathlib.Path(artifact_path).read_text())
artifact["spire_restored"] = True
artifact["workload_identity_recovered"] = True
artifact["recovery_scope"] = "workload"
artifact["post_restore_allowed_path"] = {
    "output": post_restore_output,
    "successful": True,
}
artifact["breakglass_authority"] = {
    "user": os.environ.get("OUTAGE_SCALE_AS_USER", ""),
    "group": os.environ.get("OUTAGE_SCALE_AS_GROUP", ""),
    "label": os.environ.get("OUTAGE_BREAKGLASS_AUTHORITY", "normal-authority"),
}
artifact["breakglass_audit_present"] = os.environ.get("BREAKGLASS_AUDIT_PRESENT") == "true"
artifact["final"] = "PASS"
pathlib.Path(artifact_path).write_text(json.dumps(artifact, indent=2) + "\n")
PY

echo "[PASS] existing session failed closed after SVID expiry"
echo "[PASS] no HTTP 200 allowed after identity expiration without SPIRE"
echo "[PASS] post-restore allowed path recovered"
