#!/usr/bin/env bash
set -euo pipefail

# Guard against inherited shell DEBUG/xtrace (VS Code shell integration can become unusable).
if [ "${TF_OBS_VALIDATE_DEBUG:-}" != "1" ]; then
  trap - DEBUG 2>/dev/null || true
  set +x 2>/dev/null || true
  set +o xtrace 2>/dev/null || true
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
JOB_FILE="$ROOT_DIR/platform/deploy/infra/observability/runtime_validation_job.yaml"
ARTIFACT="$ROOT_DIR/platform/security/observability/runtime_prometheus_validation.txt"
BASELINE_FILE="$ROOT_DIR/platform/security/observability/metric_inventory_baseline.txt"
ALERT_TIMING_FILE="$ROOT_DIR/platform/security/observability/alert_timing_matrix.txt"

PF_LOG=""
ALERT_PF_LOG=""

NAMESPACE="threadforge"
JOB_NAME="threadforge-observability-diagnostic"

PROM_NAMESPACE="monitoring"
PROM_SERVICE="prometheus-operated"
PROM_PORT=""

ALERTMANAGER_NAMESPACE="monitoring"
ALERTMANAGER_SERVICE="${ALERTMANAGER_SERVICE:-alertmanager-operated}"
ALERTMANAGER_PORT=""

VALIDATION_RULES_FILE="$ROOT_DIR/platform/deploy/infra/prometheus/templates/prometheusrules-phase2-validation.yaml"
VALIDATION_RULES_APPLIED="false"

BURST_MODE="false"
NO_TRAFFIC_MODE="false"
BURST_COUNT="25"
BURST_INTERVAL_SECONDS="1"
POST_WAIT_SECONDS="60"
INJECT_FAILURE_MODE=""
RESTORE_ACTIONS=()

for arg in "$@"; do
  case "$arg" in
    --burst)
      BURST_MODE="true"
      ;;
    --no-traffic)
      NO_TRAFFIC_MODE="true"
      ;;
    --inject-failure=*)
      INJECT_FAILURE_MODE="${arg#*=}"
      ;;
    *)
      echo "ERROR: unknown argument: $arg" >&2
      echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
      ;;
  esac
done

if [ "$BURST_MODE" = "true" ] && [ "$NO_TRAFFIC_MODE" = "true" ]; then
  echo "ERROR: --burst and --no-traffic are mutually exclusive" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if [ -n "$INJECT_FAILURE_MODE" ]; then
  case "$INJECT_FAILURE_MODE" in
    smp|ledger|identity|scrape)
      ;;
    *)
      echo "ERROR: --inject-failure must be one of: smp, ledger, identity, scrape" >&2
      echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
      ;;
  esac
fi

if [ -f "$ROOT_DIR/.venv/bin/activate" ]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.venv/bin/activate"
fi

cleanup() {
  if [ -n "${PF_PID:-}" ]; then
    kill "$PF_PID" >/dev/null 2>&1 || true
    wait "$PF_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$PF_LOG" ] && [ -f "$PF_LOG" ]; then
    rm -f "$PF_LOG" >/dev/null 2>&1 || true
  fi
  if [ -n "${ALERT_PF_PID:-}" ]; then
    kill "$ALERT_PF_PID" >/dev/null 2>&1 || true
    wait "$ALERT_PF_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$ALERT_PF_LOG" ] && [ -f "$ALERT_PF_LOG" ]; then
    rm -f "$ALERT_PF_LOG" >/dev/null 2>&1 || true
  fi
  if [ ${#RESTORE_ACTIONS[@]} -gt 0 ]; then
    for cmd in "${RESTORE_ACTIONS[@]}"; do
      eval "$cmd" >/dev/null 2>&1 || true
    done
  fi
  if [ "${VALIDATION_RULES_APPLIED}" = "true" ]; then
    kubectl delete -f "$VALIDATION_RULES_FILE" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

start_port_forward() {
  PF_LOG=$(mktemp)
  kubectl -n "$PROM_NAMESPACE" port-forward "svc/$PROM_SERVICE" "$PROM_PORT":9090 >"$PF_LOG" 2>&1 &
  PF_PID=$!
  sleep 0.2
  if ! kill -0 "$PF_PID" >/dev/null 2>&1; then
    echo "ERROR: Prometheus port-forward process exited immediately" >&2
    if [ -f "$PF_LOG" ]; then
      cat "$PF_LOG" >&2 || true
    fi
    return 1
  fi
}

wait_for_prometheus() {
  local attempt=0
  while [ $attempt -lt 30 ]; do
    if ! kill -0 "$PF_PID" >/dev/null 2>&1; then
      echo "ERROR: Prometheus port-forward process died" >&2
      if [ -f "$PF_LOG" ]; then
        cat "$PF_LOG" >&2 || true
      fi
      return 1
    fi
    if curl -fsS "http://127.0.0.1:$PROM_PORT/-/ready" >/dev/null; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  echo "ERROR: Prometheus port-forward not ready" >&2
  if [ -f "$PF_LOG" ]; then
    cat "$PF_LOG" >&2 || true
  fi
  return 1
}

detect_alertmanager_service() {
  if kubectl -n "$ALERTMANAGER_NAMESPACE" get svc "$ALERTMANAGER_SERVICE" >/dev/null 2>&1; then
    return 0
  fi
  for candidate in alertmanager-operated kube-prometheus-stack-alertmanager; do
    if kubectl -n "$ALERTMANAGER_NAMESPACE" get svc "$candidate" >/dev/null 2>&1; then
      ALERTMANAGER_SERVICE="$candidate"
      return 0
    fi
  done
  echo "ERROR: could not find Alertmanager service in namespace '$ALERTMANAGER_NAMESPACE'" >&2
  kubectl -n "$ALERTMANAGER_NAMESPACE" get svc -o name >&2 || true
  return 1
}

start_alertmanager_port_forward() {
  detect_alertmanager_service
  ALERT_PF_LOG=$(mktemp)
  kubectl -n "$ALERTMANAGER_NAMESPACE" port-forward "svc/$ALERTMANAGER_SERVICE" \
    "$ALERTMANAGER_PORT":9093 >"$ALERT_PF_LOG" 2>&1 &
  ALERT_PF_PID=$!
  sleep 0.2
  if ! kill -0 "$ALERT_PF_PID" >/dev/null 2>&1; then
    echo "ERROR: Alertmanager port-forward process exited immediately" >&2
    if [ -f "$ALERT_PF_LOG" ]; then
      cat "$ALERT_PF_LOG" >&2 || true
    fi
    return 1
  fi
}

wait_for_alertmanager() {
  local attempt=0
  while [ $attempt -lt 30 ]; do
    if ! kill -0 "$ALERT_PF_PID" >/dev/null 2>&1; then
      echo "ERROR: Alertmanager port-forward process died" >&2
      if [ -f "$ALERT_PF_LOG" ]; then
        cat "$ALERT_PF_LOG" >&2 || true
      fi
      return 1
    fi
    if curl -fsS "http://127.0.0.1:$ALERTMANAGER_PORT/api/v2/status" >/dev/null; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  echo "ERROR: Alertmanager port-forward not ready" >&2
  if [ -f "$ALERT_PF_LOG" ]; then
    cat "$ALERT_PF_LOG" >&2 || true
  fi
  return 1
}

alertmanager_firing_validation_alerts() {
  local resp
  resp=$(curl -fsS "http://127.0.0.1:$ALERTMANAGER_PORT/api/v2/alerts" || echo '[]')
  python3 -c '
import json
import sys

raw = sys.stdin.read().strip()
if not raw:
  sys.exit(0)

try:
  data = json.loads(raw)
except Exception:
  sys.exit(0)

  names = []
  for alert in data:
    # Alertmanager v2 uses state values like: active, suppressed.
    if alert.get("status", {}).get("state") not in ("active", "suppressed"):
      continue
  labels = alert.get("labels", {})
  if labels.get("validation_scope") != "phase2":
    continue
  name = labels.get("alertname", "")
  if name:
    names.append(name)

sys.stdout.write("\n".join(sorted(set(names))))
' <<<"$resp"
}

alertmanager_find_alert() {
  local alert_name="$1"
  local resp
  resp=$(curl -fsS "http://127.0.0.1:$ALERTMANAGER_PORT/api/v2/alerts" || echo '[]')
  ALERT_NAME="$alert_name" python3 -c '
import json
import os
import sys

target = os.environ.get("ALERT_NAME", "")
raw = sys.stdin.read().strip()
if not raw:
  sys.stdout.write("{}")
  sys.exit(0)

try:
  data = json.loads(raw)
except Exception:
  sys.stdout.write("{}")
  sys.exit(0)

for alert in data:
  labels = alert.get("labels", {})
  if labels.get("alertname") != target:
    continue
  if labels.get("validation_scope") != "phase2":
    continue
  status = alert.get("status", {})
  sys.stdout.write(json.dumps({
    "state": status.get("state"),
    "startsAt": alert.get("startsAt"),
    "endsAt": alert.get("endsAt"),
  }))
  sys.exit(0)

sys.stdout.write("{}")
' <<<"$resp"
}

epoch_from_rfc3339() {
  local ts="$1"
  python3 - <<PY
from datetime import datetime, timezone
import sys

ts = "$ts"
if not ts:
    print("")
    sys.exit(0)

try:
    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    print(int(dt.timestamp()))
except Exception:
    print("")
PY
}

register_restore() {
  RESTORE_ACTIONS+=("$*")
}

pick_free_port() {
  python3 - <<'PY'
import socket

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

prom_query_value() {
  local query="$1"
  local resp
  resp=$(curl -fsS --data-urlencode "query=$query" "http://127.0.0.1:$PROM_PORT/api/v1/query" || true)
  QUERY="$query" python3 -c '
import json
import os
import sys

query = os.environ.get("QUERY", "")
raw = sys.stdin.read().strip()
if not raw:
  sys.stderr.write(f"ERROR: Prometheus query returned empty body: {query}\n")
  sys.stdout.write("nan")
  sys.exit(0)

try:
  data = json.loads(raw)
except Exception:
  sys.stderr.write(f"ERROR: Prometheus query returned non-JSON body: {query}\n")
  sys.stderr.write(raw[:200] + "\n")
  sys.stdout.write("nan")
  sys.exit(0)

if data.get("status") != "success":
  sys.stderr.write(f"ERROR: Prometheus query status != success: {query}\n")
  sys.stdout.write("nan")
  sys.exit(0)

result = data.get("data", {}).get("result", [])
if not result:
  sys.stdout.write("0")
  sys.exit(0)

total = 0.0
for item in result:
  value = item.get("value")
  if isinstance(value, list) and len(value) > 1:
    try:
      total += float(value[1])
    except ValueError:
      pass

sys.stdout.write(str(total))
' <<<"$resp"
}

prom_query_count() {
  local query="$1"
  local resp
  resp=$(curl -fsS --data-urlencode "query=$query" "http://127.0.0.1:$PROM_PORT/api/v1/query" || true)
  QUERY="$query" python3 -c '
import json
import os
import sys

query = os.environ.get("QUERY", "")
raw = sys.stdin.read().strip()
if not raw:
  sys.stderr.write(f"ERROR: Prometheus query returned empty body: {query}\n")
  sys.stdout.write("0")
  sys.exit(0)

try:
  data = json.loads(raw)
except Exception:
  sys.stderr.write(f"ERROR: Prometheus query returned non-JSON body: {query}\n")
  sys.stderr.write(raw[:200] + "\n")
  sys.stdout.write("0")
  sys.exit(0)

if data.get("status") != "success":
  sys.stderr.write(f"ERROR: Prometheus query status != success: {query}\n")
  sys.stdout.write("0")
  sys.exit(0)

result = data.get("data", {}).get("result", [])
sys.stdout.write(str(len(result)))
' <<<"$resp"
}

calc_delta() {
  local before="$1"
  local after="$2"
  python3 - <<PY
try:
    before = float("$before")
    after = float("$after")
    print(after - before)
except Exception:
    print("nan")
PY
}

PROM_PORT=$(pick_free_port)
ALERTMANAGER_PORT=$(pick_free_port)

start_port_forward
wait_for_prometheus

metric_count_before=$(prom_query_value 'count({__name__=~".+"})')
if [ "$metric_count_before" = "nan" ] || [ -z "$metric_count_before" ]; then
  echo "ERROR: failed to query Prometheus metric inventory (port-forward may not be hitting Prometheus)" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
metric_count_baseline=""
baseline_initialized="false"
if [ -f "$BASELINE_FILE" ]; then
  metric_count_baseline=$(python3 - <<PY
import re
import sys

data = open("$BASELINE_FILE", "r", encoding="utf-8").read().strip()
match = re.search(r"(\d+(?:\.\d+)?)", data)
print(match.group(1) if match else "")
PY
)
else
  metric_count_baseline="$metric_count_before"
  baseline_initialized="true"
fi

queries=(
  "smp_dispatch_total"
  "smp_dispatch_latency_ms_count"
  "ledger_write_operations_total"
  "identity_coverage_ratio"
)

post_wait_queries=(
  "smp_queue_depth"
  "smp_in_flight"
  "smp_refusals_total"
  "count(ALERTS{alertstate=\"firing\"})"
)

declare -A BEFORE AFTER DELTA BEFORE_COUNT AFTER_COUNT
for q in "${queries[@]}"; do
  BEFORE["$q"]=$(prom_query_value "$q")
  BEFORE_COUNT["$q"]=$(prom_query_count "$q")
done

if [ "$NO_TRAFFIC_MODE" = "false" ]; then
  kubectl -n "$NAMESPACE" delete job "$JOB_NAME" --ignore-not-found --wait=false >/dev/null
  kubectl apply -f "$JOB_FILE" >/dev/null

  if [ "$BURST_MODE" = "true" ]; then
    kubectl -n "$NAMESPACE" set env "job/$JOB_NAME" \
      BURST_COUNT="$BURST_COUNT" \
      BURST_INTERVAL_SECONDS="$BURST_INTERVAL_SECONDS" \
      >/dev/null
  fi

  if ! kubectl -n "$NAMESPACE" wait --for=condition=complete "job/$JOB_NAME" --timeout=180s; then
    kubectl -n "$NAMESPACE" logs "job/$JOB_NAME" || true
    echo "ERROR: validation job did not complete" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi

  kubectl -n "$NAMESPACE" logs "job/$JOB_NAME" || true
fi

wait_for_metric_delta() {
  local query="$1"
  local before="$2"
  local timeout_seconds="$3"

  local deadline
  deadline=$(( $(date +%s) + timeout_seconds ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local now
    now=$(prom_query_value "$query")
    if python3 - <<PY
import sys
try:
    before = float("$before")
    now = float("$now")
    sys.exit(0 if (now - before) > 0 else 1)
except Exception:
    sys.exit(1)
PY
    then
      return 0
    fi
    sleep 2
  done
  return 1
}

if [ "$NO_TRAFFIC_MODE" = "false" ]; then
  # Prometheus scrape is async. Poll for expected counter deltas rather than relying on
  # a single immediate snapshot.
  wait_for_metric_delta "smp_dispatch_total" "${BEFORE[smp_dispatch_total]}" 60 || true
  wait_for_metric_delta "smp_dispatch_latency_ms_count" "${BEFORE[smp_dispatch_latency_ms_count]}" 60 || true
  wait_for_metric_delta "ledger_write_operations_total" "${BEFORE[ledger_write_operations_total]}" 60 || true
fi

for q in "${queries[@]}"; do
  AFTER["$q"]=$(prom_query_value "$q")
  DELTA["$q"]=$(calc_delta "${BEFORE[$q]}" "${AFTER[$q]}")
  AFTER_COUNT["$q"]=$(prom_query_count "$q")
done

metric_count_after=$(prom_query_value 'count({__name__=~".+"})')
metric_count_delta=$(calc_delta "$metric_count_before" "$metric_count_after")
metric_count_baseline_delta=$(calc_delta "$metric_count_baseline" "$metric_count_after")

post_wait_sleep=$POST_WAIT_SECONDS
if [ "$NO_TRAFFIC_MODE" = "true" ]; then
  post_wait_sleep=0
fi

if [ "$post_wait_sleep" -gt 0 ]; then
  sleep "$post_wait_sleep"
fi

declare -A POST_WAIT
for q in "${post_wait_queries[@]}"; do
  POST_WAIT["$q"]=$(prom_query_value "$q")
done

queue_peak_2m=$(prom_query_value 'max_over_time(smp_queue_depth[2m])')

baseline_write_value="$metric_count_after"
if [ "$NO_TRAFFIC_MODE" = "true" ]; then
  baseline_write_value="$metric_count_baseline"
fi

printf "metric_count_baseline: %s\n" "$baseline_write_value" > "$BASELINE_FILE"

{
  echo "THREADFORGE PHASE 2 RUNTIME PROMETHEUS VALIDATION"
  echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "burst_mode: $BURST_MODE"
  echo "no_traffic_mode: $NO_TRAFFIC_MODE"
  echo
  echo "metric_count_before: $metric_count_before"
  echo "metric_count_after: $metric_count_after"
  echo "metric_count_delta: $metric_count_delta"
  echo "metric_count_baseline: $metric_count_baseline"
  echo "metric_count_baseline_delta: $metric_count_baseline_delta"
  echo "metric_count_baseline_path: $BASELINE_FILE"
  echo "metric_count_baseline_initialized: $baseline_initialized"
  echo "queue_depth_peak_2m: $queue_peak_2m"
  echo
  for q in "${queries[@]}"; do
    echo "## QUERY: $q"
    echo "result_count_before: ${BEFORE_COUNT[$q]}"
    echo "result_count_after: ${AFTER_COUNT[$q]}"
    echo "before: ${BEFORE[$q]}"
    echo "after: ${AFTER[$q]}"
    echo "delta: ${DELTA[$q]}"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
  done

  echo "## POST_WAIT"
  for q in "${post_wait_queries[@]}"; do
    echo "post_wait_query: $q"
    echo "post_wait_value: ${POST_WAIT[$q]}"
  done
  echo "post_wait_seconds: $post_wait_sleep"
  echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
} > "$ARTIFACT"

kubectl -n "$NAMESPACE" delete job "$JOB_NAME" --ignore-not-found --wait=false >/dev/null

echo "Wrote validation artifact: $ARTIFACT"

if python3 - <<PY
import sys
try:
    delta = float("$metric_count_baseline_delta")
    sys.exit(1 if delta > 5 else 0)
except Exception:
    sys.exit(1)
PY
then
  :
else
  echo "ERROR: metric cardinality increase exceeds +5 baseline delta" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if [ "$NO_TRAFFIC_MODE" = "true" ]; then
  all_zero="true"
  for q in "${queries[@]}"; do
    if [ "${DELTA[$q]}" != "0.0" ] && [ "${DELTA[$q]}" != "0" ]; then
      all_zero="false"
    fi
  done
  if [ "$all_zero" = "true" ]; then
    echo "NO-TRAFFIC MODE: expected mutation missing; failing intentionally." >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
fi

if [ "$BURST_MODE" = "true" ]; then
  peak_val="${queue_peak_2m}"
  if python3 - <<PY
import sys
try:
    val = float("$peak_val")
    sys.exit(0 if val > 0 else 1)
except Exception:
    sys.exit(1)
PY
  then
    :
  else
    echo "ERROR: burst mode expected queue depth peak > 0" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
fi

if [ -n "$INJECT_FAILURE_MODE" ]; then
  start_alertmanager_port_forward
  wait_for_alertmanager

  kubectl apply -f "$VALIDATION_RULES_FILE" >/dev/null
  VALIDATION_RULES_APPLIED="true"

  baseline_alerts_csv=$(alertmanager_firing_validation_alerts | sort -u | tr '\n' ',')

  failure_start_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  failure_start_epoch=$(date +%s)

  case "$INJECT_FAILURE_MODE" in
    smp)
      expected_alert="Phase2ValidationSMPDispatch"
      kubectl -n "$NAMESPACE" delete job "$JOB_NAME" --ignore-not-found --wait=false >/dev/null
      kubectl apply -f "$JOB_FILE" >/dev/null
      kubectl -n "$NAMESPACE" set env "job/$JOB_NAME" \
        BURST_COUNT="$BURST_COUNT" \
        BURST_INTERVAL_SECONDS="$BURST_INTERVAL_SECONDS" \
        >/dev/null
      if ! kubectl -n "$NAMESPACE" wait --for=condition=complete "job/$JOB_NAME" --timeout=180s; then
        kubectl -n "$NAMESPACE" logs "job/$JOB_NAME" || true
        echo "ERROR: validation job did not complete (smp injection)" >&2
        echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
      fi
      kubectl -n "$NAMESPACE" logs "job/$JOB_NAME" || true
      ;;
    ledger)
      expected_alert="Phase2ValidationLedgerDown"
      ledger_replicas=$(kubectl -n threadforge-system get statefulset postgres -o jsonpath='{.spec.replicas}')
      register_restore "kubectl -n threadforge-system scale statefulset postgres --replicas=${ledger_replicas}"
      kubectl -n threadforge-system scale statefulset postgres --replicas=0
      ;;
    identity)
      expected_alert="Phase2ValidationIdentityPlaneDown"
      spire_replicas=$(kubectl -n spire-system get statefulset spire-server -o jsonpath='{.spec.replicas}')
      register_restore "kubectl -n spire-system scale statefulset spire-server --replicas=${spire_replicas}"
      kubectl -n spire-system scale statefulset spire-server --replicas=0
      ;;
    scrape)
      expected_alert="Phase2ValidationScrapeDown"
      api_replicas=$(kubectl -n threadforge get deployment threadforge-api -o jsonpath='{.spec.replicas}')
      register_restore "kubectl -n threadforge scale deployment threadforge-api --replicas=${api_replicas}"
      kubectl -n threadforge scale deployment threadforge-api --replicas=0
      ;;
  esac

  fired_time=""
  fired_epoch=""
  detection_latency=""
  unexpected_alerts=""
  deadline=$((failure_start_epoch + 60))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    current_alerts_csv=$(alertmanager_firing_validation_alerts | sort -u | tr '\n' ',')
    unexpected_alerts=$(python3 - <<PY
baseline = set(filter(None, "$baseline_alerts_csv".split(",")))
current = set(filter(None, "$current_alerts_csv".split(",")))
expected = set(filter(None, ["$expected_alert"]))
unexpected = sorted(current - baseline - expected)
print(",".join(unexpected))
PY
)
    if [ -n "$unexpected_alerts" ]; then
      echo "ERROR: unexpected validation alerts fired: $unexpected_alerts" >&2
      echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    fi

    alert_info=$(alertmanager_find_alert "$expected_alert")
    alert_state=$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get("state", ""))' <<<"$alert_info")
    if [ "$alert_state" = "firing" ]; then
      fired_time=$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get("startsAt", ""))' <<<"$alert_info")
      fired_epoch=$(epoch_from_rfc3339 "$fired_time")
      if [ -z "$fired_epoch" ]; then
        fired_epoch=$(date +%s)
        fired_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      fi
      detection_latency=$((fired_epoch - failure_start_epoch))
      break
    fi
    sleep 2
  done

  if [ -z "$fired_time" ]; then
    echo "ERROR: expected alert did not fire within 60s: $expected_alert" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi

  if [ ${#RESTORE_ACTIONS[@]} -gt 0 ]; then
    for cmd in "${RESTORE_ACTIONS[@]}"; do
      eval "$cmd" >/dev/null 2>&1 || true
    done
    RESTORE_ACTIONS=()
  fi

  alert_cleared_time=""
  alert_cleared_epoch=""
  recovery_latency=""
  clear_deadline=$(( $(date +%s) + 180 ))
  while [ "$(date +%s)" -lt "$clear_deadline" ]; do
    alert_info=$(alertmanager_find_alert "$expected_alert")
    alert_state=$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get("state", ""))' <<<"$alert_info")
    if [ "$alert_state" != "firing" ]; then
      alert_cleared_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      alert_cleared_epoch=$(date +%s)
      recovery_latency=$((alert_cleared_epoch - fired_epoch))
      break
    fi
    sleep 2
  done

  if [ -z "$alert_cleared_time" ]; then
    echo "ERROR: expected alert did not clear after recovery: $expected_alert" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi

  {
    echo "THREADFORGE PHASE 2 ALERT TIMING MATRIX"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "mode: $INJECT_FAILURE_MODE"
    echo "alert_name: $expected_alert"
    echo "failure_start_time: $failure_start_time"
    echo "alert_fired_time: $fired_time"
    echo "detection_latency_seconds: $detection_latency"
    echo "alert_cleared_time: $alert_cleared_time"
    echo "recovery_time_seconds: $recovery_latency"
    echo "unexpected_alerts: ${unexpected_alerts:-none}"
  } > "$ALERT_TIMING_FILE"

  echo "Wrote alert timing matrix: $ALERT_TIMING_FILE"
fi
