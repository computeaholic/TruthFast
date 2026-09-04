#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=EVENT

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

kubectl() {
  run_real_kubectl "$@"
}

EVENT_DIR="$REPO_ROOT/artifacts/events"
PROOF_EVENTS_PATH="$EVENT_DIR/proof_events.jsonl"
NOTIFIER_EVENTS_PATH="$EVENT_DIR/notifier_events.jsonl"
REMEDIATION_EVENTS_PATH="$EVENT_DIR/remediation.log"
ARTIFACT_PATH="$REPO_ROOT/artifacts/closed_loop_validation.json"
DEBUG_LOG_PATH="$REPO_ROOT/artifacts/debug/closed_loop_failure.log"

NOTIFIER_NS="threadforge-system"
NOTIFIER_NAME="threadforge-notifier"
TEST_NS="threadforge-test"
TEST_LABEL="app=test-client"
NOTIFIER_SERVICE_URL="http://threadforge-notifier.threadforge-system.svc.cluster.local:8080"
MODE="${CLOSED_LOOP_VALIDATION_MODE:-full}"
CURRENT_RUN_ID="${PROOF_RUN_ID:-}"
SYNTHETIC_RUN_ID="closed-loop-validation-$(date -u +%Y%m%dT%H%M%SZ)"
SYNTHETIC_PHASE="closed-loop-synthetic-phase"
NOTIFIER_EVENT_LOG_PATH="/var/lib/threadforge-notifier/events/notifier_events.jsonl"
REMEDIATION_LOG_PATH="/var/lib/threadforge-notifier/events/remediation.log"

FAILURES=0
FAIL_MESSAGES=()
phase_event_payload=""
final_event_payload=""

pod_for_label() {
  local namespace="$1"
  local selector="$2"

  kubectl get pods -n "$namespace" -l "$selector" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.deletionTimestamp}{"\t"}{.status.phase}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' 2>/dev/null \
    | awk -F '\t' '($2 == "" && $3 == "Running") { print ($4 == "True" ? 0 : 1) "\t" NR "\t" $1 }' \
    | sort -n -k1,1 -k2,2 \
    | head -n1 \
    | cut -f3
}

snapshot_notifier_file() {
  local notifier_pod="$1"
  local remote_path="$2"
  local local_path="$3"
  local attempts="${4:-10}"
  local delay_seconds="${5:-2}"
  local attempt

  for attempt in $(seq 1 "$attempts"); do
    if kubectl exec -n "$NOTIFIER_NS" "$notifier_pod" -c threadforge-notifier -- cat "$remote_path" > "$local_path" 2>/dev/null; then
      return 0
    fi
    sleep "$delay_seconds"
  done

  return 1
}

wait_for_event_in_snapshot() {
  local notifier_pod="$1"
  local run_id="$2"
  local remote_path="$3"
  local local_path="$4"
  local attempts="${5:-10}"
  local delay_seconds="${6:-2}"
  local attempt

  for attempt in $(seq 1 "$attempts"); do
    if snapshot_notifier_file "$notifier_pod" "$remote_path" "$local_path" 1 "$delay_seconds" \
      && grep -F '"run_id":"'$run_id'"' "$local_path" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay_seconds"
  done

  return 1
}

fail() {
  local msg="$1"
  echo "[FAIL] $msg"
  FAILURES=$((FAILURES + 1))
  FAIL_MESSAGES+=("$msg")
}

pass() {
  local msg="$1"
  if [ "$FAILURES" -eq 0 ]; then
    echo "[PASS] $msg"
  else
    echo "[closed-loop] note: $msg"
  fi
}

write_failure_debug_log() {
  local notifier_pod="$1"
  local notifier_logs=""
  local notifier_events=""
  if [ -n "$notifier_pod" ]; then
    notifier_logs="$(kubectl logs -n "$NOTIFIER_NS" "$notifier_pod" -c threadforge-notifier --tail=200 2>&1 || true)"
    notifier_events="$(kubectl exec -n "$NOTIFIER_NS" "$notifier_pod" -c threadforge-notifier -- sh -lc "grep -n '$CURRENT_RUN_ID\|$SYNTHETIC_RUN_ID' '$NOTIFIER_EVENT_LOG_PATH' || true" 2>&1 || true)"
    kubectl exec -n "$NOTIFIER_NS" "$notifier_pod" -c threadforge-notifier -- cat "$NOTIFIER_EVENT_LOG_PATH" > "$NOTIFIER_EVENTS_PATH" 2>/dev/null || true
  fi
  mkdir -p "$(dirname "$DEBUG_LOG_PATH")"
  {
    echo "run_id=$CURRENT_RUN_ID"
    echo "synthetic_run_id=$SYNTHETIC_RUN_ID"
    echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "phase_event_payload=$phase_event_payload"
    echo "final_event_payload=$final_event_payload"
    echo "local_emitted_events<<'EOF'"
    rg -n "\"run_id\":\"$CURRENT_RUN_ID\"|\"run_id\":\"$SYNTHETIC_RUN_ID\"" "$PROOF_EVENTS_PATH" 2>/dev/null || true
    echo "EOF"
    echo "notifier_events<<'EOF'"
    printf '%s\n' "$notifier_events"
    echo "EOF"
    echo "notifier_logs<<'EOF'"
    printf '%s\n' "$notifier_logs"
    echo "EOF"
  } > "$DEBUG_LOG_PATH"
}

metric_value() {
  local raw="$1"
  local pattern="$2"
  printf '%s\n' "$raw" | awk -v r="$pattern" '$0 ~ r {print $NF; found=1; exit} END {if (!found) print "0"}'
}

post_event_via_test_client() {
  local pod="$1"
  local payload_json="$2"
  local payload_b64 http_code attempt

  payload_b64="$(printf '%s' "$payload_json" | base64 | tr -d '\n')"
  for attempt in $(seq 1 10); do
    http_code="$(kubectl exec -n "$TEST_NS" "$pod" -c test-client -- sh -lc "printf '%s' '$payload_b64' | base64 -d | curl -s -o /tmp/closed_loop_notify.out -w '%{http_code}' -H 'Content-Type: application/json' --data-binary @- '$NOTIFIER_SERVICE_URL/notify' && cat /tmp/closed_loop_notify.out >/dev/null" 2>/dev/null || true)"
    http_code="${http_code:0:3}"
    if [ "$http_code" = "200" ]; then
      printf '%s' "$http_code"
      return 0
    fi
    sleep 2
  done
  printf '%s' "$http_code"
}

read_notifier_metrics() {
  local pod="$1"
  local metrics=""
  local attempt

  for attempt in $(seq 1 10); do
    metrics="$(kubectl exec -n "$TEST_NS" "$pod" -c test-client -- curl -sf "$NOTIFIER_SERVICE_URL/metrics" 2>/dev/null || true)"
    if [ -n "$metrics" ]; then
      printf '%s' "$metrics"
      return 0
    fi
    sleep 2
  done

  return 1
}

mkdir -p "$EVENT_DIR"

ensure_cluster_readable || exit $?

notifier_pod="$(pod_for_label "$NOTIFIER_NS" "app=$NOTIFIER_NAME")"
test_client_pod="$(pod_for_label "$TEST_NS" "$TEST_LABEL")"

if [ -z "$notifier_pod" ]; then
  fail "no running notifier pod found"
fi
if [ -z "$test_client_pod" ]; then
  fail "no running test-client pod found"
fi
if [ ! -f "$PROOF_EVENTS_PATH" ]; then
  fail "proof event log missing: $PROOF_EVENTS_PATH"
fi

if [ -z "$CURRENT_RUN_ID" ]; then
  CURRENT_RUN_ID="$(/home/threadforge/threadforge/.venv/bin/python - "$PROOF_EVENTS_PATH" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
run_id = ""
for line in path.read_text().splitlines()[-20:]:
    line = line.strip()
    if not line:
        continue
    try:
        payload = json.loads(line)
    except Exception:
        continue
    value = payload.get("run_id", "")
    if value:
        run_id = value
print(run_id)
PY
)"
fi

if [ -z "$CURRENT_RUN_ID" ]; then
  fail "could not determine proof run_id from local event log"
fi

required_phase_count="5"
observed_phase_count="$(grep -F '"type":"proof_phase"' "$PROOF_EVENTS_PATH" | grep -F '"run_id":"'$CURRENT_RUN_ID'"' | wc -l | tr -d ' ')"
if [ "$observed_phase_count" -lt "$required_phase_count" ]; then
  fail "local proof event log does not contain expected phase events for run $CURRENT_RUN_ID"
else
  pass "local proof event log contains $observed_phase_count phase events for run $CURRENT_RUN_ID"
fi

before_metrics="$(read_notifier_metrics "$test_client_pod" || true)"
if [ -z "$before_metrics" ]; then
  fail "failed to read notifier metrics before validation"
fi

before_runs="$(metric_value "$before_metrics" '^threadforge_proof_runs_total ')"
before_failures="$(metric_value "$before_metrics" '^threadforge_proof_failures_total ')"
before_phase_failures="$(metric_value "$before_metrics" '^threadforge_proof_phase_failures_total{phase="closed-loop-synthetic-phase"} ')"

phase_event_payload="$(cat <<JSON
{"type":"proof_phase","phase":"$SYNTHETIC_PHASE","status":"FAIL","fail_class":"SYSTEM_REGRESSION","timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","run_id":"$SYNTHETIC_RUN_ID","details":{"synthetic":true,"source":"validate_closed_loop"}}
JSON
)"
final_event_payload="$(cat <<JSON
{"type":"proof_final","final":"FAIL","status":"FAIL","fail_class":"SYSTEM_REGRESSION","strict_mode":true,"advisory_count":0,"timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","run_id":"$SYNTHETIC_RUN_ID","details":{"synthetic":true,"source":"validate_closed_loop"}}
JSON
)"

phase_http_code="$(post_event_via_test_client "$test_client_pod" "$phase_event_payload")"
if [ "$phase_http_code" != "200" ]; then
  fail "synthetic proof phase event POST returned HTTP $phase_http_code"
else
  pass "synthetic proof phase event accepted"
fi

final_http_code="$(post_event_via_test_client "$test_client_pod" "$final_event_payload")"
if [ "$final_http_code" != "200" ]; then
  fail "synthetic proof final event POST returned HTTP $final_http_code"
else
  pass "synthetic proof final event accepted"
fi

duplicate_http_code="$(post_event_via_test_client "$test_client_pod" "$final_event_payload")"
if [ "$duplicate_http_code" != "200" ]; then
  fail "duplicate synthetic proof final event POST returned HTTP $duplicate_http_code"
else
  pass "duplicate synthetic proof final event accepted for dedupe testing"
fi

if ! snapshot_notifier_file "$notifier_pod" "$NOTIFIER_EVENT_LOG_PATH" "$NOTIFIER_EVENTS_PATH"; then
  fail "failed to snapshot notifier event log"
fi
if ! snapshot_notifier_file "$notifier_pod" "$REMEDIATION_LOG_PATH" "$REMEDIATION_EVENTS_PATH"; then
  fail "failed to snapshot notifier remediation log"
fi

if ! wait_for_event_in_snapshot "$notifier_pod" "$CURRENT_RUN_ID" "$NOTIFIER_EVENT_LOG_PATH" "$NOTIFIER_EVENTS_PATH"; then
  fail "notifier event log does not contain proof events for current run $CURRENT_RUN_ID"
else
  pass "notifier event log contains current proof run events"
fi

if ! wait_for_event_in_snapshot "$notifier_pod" "$SYNTHETIC_RUN_ID" "$NOTIFIER_EVENT_LOG_PATH" "$NOTIFIER_EVENTS_PATH"; then
  fail "notifier event log does not contain synthetic failure events"
else
  pass "notifier event log contains synthetic failure events"
fi

if ! snapshot_notifier_file "$notifier_pod" "$REMEDIATION_LOG_PATH" "$REMEDIATION_EVENTS_PATH"; then
  fail "failed to refresh notifier remediation log after event delivery"
fi

after_metrics="$(read_notifier_metrics "$test_client_pod" || true)"
if [ -z "$after_metrics" ]; then
  fail "failed to read notifier metrics after validation"
fi

after_runs="$(metric_value "$after_metrics" '^threadforge_proof_runs_total ')"
after_failures="$(metric_value "$after_metrics" '^threadforge_proof_failures_total ')"
after_phase_failures="$(metric_value "$after_metrics" '^threadforge_proof_phase_failures_total{phase="closed-loop-synthetic-phase"} ')"

if ! /home/threadforge/threadforge/.venv/bin/python - "$before_runs" "$after_runs" <<'PY'
import sys
before = float(sys.argv[1])
after = float(sys.argv[2])
raise SystemExit(0 if after == before + 1 else 1)
PY
then
  fail "threadforge_proof_runs_total did not increment by exactly 1"
else
  pass "threadforge_proof_runs_total incremented by 1"
fi

if ! /home/threadforge/threadforge/.venv/bin/python - "$before_failures" "$after_failures" <<'PY'
import sys
before = float(sys.argv[1])
after = float(sys.argv[2])
raise SystemExit(0 if after == before + 1 else 1)
PY
then
  fail "threadforge_proof_failures_total did not increment by exactly 1"
else
  pass "threadforge_proof_failures_total incremented by 1"
fi

if ! /home/threadforge/threadforge/.venv/bin/python - "$before_phase_failures" "$after_phase_failures" <<'PY'
import sys
before = float(sys.argv[1])
after = float(sys.argv[2])
raise SystemExit(0 if after == before + 1 else 1)
PY
then
  fail "threadforge_proof_phase_failures_total for synthetic phase did not increment by exactly 1"
else
  pass "threadforge_proof_phase_failures_total incremented by 1"
fi

remediation_count="$( (grep -F "run_id=$SYNTHETIC_RUN_ID" "$REMEDIATION_EVENTS_PATH" || true) | wc -l | tr -d ' ' )"
if [ "$remediation_count" != "1" ]; then
  fail "remediation hook did not dedupe identical failures correctly (expected 1, got $remediation_count)"
else
  pass "remediation hook deduped identical failures within cooldown"
fi

/home/threadforge/threadforge/.venv/bin/python - "$ARTIFACT_PATH" "$FAILURES" "$CURRENT_RUN_ID" "$SYNTHETIC_RUN_ID" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = {
    "status": "PASS" if int(sys.argv[2]) == 0 else "FAIL",
    "current_run_id": sys.argv[3],
    "synthetic_run_id": sys.argv[4],
    "proof_events_path": "artifacts/events/proof_events.jsonl",
    "notifier_events_path": "artifacts/events/notifier_events.jsonl",
    "remediation_events_path": "artifacts/events/remediation.log",
    "failures": int(sys.argv[2]),
}
path.write_text(json.dumps(payload, indent=2) + "\n")
PY

if [ "$FAILURES" -gt 0 ]; then
  write_failure_debug_log "$notifier_pod"
  printf '%s\n' "${FAIL_MESSAGES[@]}" | sed 's/^/[FAIL] /'
  exit 2
fi

pass "closed-loop validation passed"
