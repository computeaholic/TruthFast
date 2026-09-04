#!/usr/bin/env bash
set -euo pipefail

# Guard against inherited shell DEBUG/xtrace (VS Code shell integration can become unusable).
if [ "${TF_OBS_CHAOS_DEBUG:-}" != "1" ]; then
  trap - DEBUG 2>/dev/null || true
  set +x 2>/dev/null || true
  set +o xtrace 2>/dev/null || true
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT_FILE="$ROOT_DIR/platform/security/observability/chaos_alert_timing_matrix.txt"
JOB_FILE="$ROOT_DIR/platform/deploy/infra/observability/runtime_validation_job.yaml"

KEEP_ON_EXIT="${TF_OBS_CHAOS_KEEP:-0}"

NAMESPACE_THREADFORGE="threadforge"
NAMESPACE_MONITORING="monitoring"
NAMESPACE_OBSERVABILITY="observability"

ALERTMANAGER_NAMESPACE="$NAMESPACE_MONITORING"
ALERTMANAGER_SERVICE="kube-prometheus-stack-alertmanager"

PROM_NAMESPACE="$NAMESPACE_MONITORING"
PROM_SERVICE="prometheus-operated"

POST_WAIT_SECONDS="60"

# Hard SLAs (fail-closed)
MAX_DETECTION_SECONDS_DEFAULT="60"
MAX_DETECTION_SECONDS_IDENTITY="90"
MAX_CLEAR_SECONDS="120"

FAILURE_MODE=""

for arg in "$@"; do
  case "$arg" in
    --failure=*)
      FAILURE_MODE="${arg#*=}"
      ;;
    *)
      echo "ERROR: unknown argument: $arg" >&2
      echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
      ;;
  esac
done

declare -a RESTORE_ACTIONS
RESTORE_ACTIONS=()

pick_free_port() {
  python3 - <<'PY'
import socket

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

cleanup() {
  if [ -n "${PF_PID:-}" ]; then
    kill "$PF_PID" >/dev/null 2>&1 || true
    wait "$PF_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "${ALERT_PF_PID:-}" ]; then
    kill "$ALERT_PF_PID" >/dev/null 2>&1 || true
    wait "$ALERT_PF_PID" >/dev/null 2>&1 || true
  fi
  # No PrometheusRule injection in Level 7 mode; rules are installed via Helm.
  if [ ${#RESTORE_ACTIONS[@]} -gt 0 ]; then
    for cmd in "${RESTORE_ACTIONS[@]}"; do
      eval "$cmd" >/dev/null 2>&1 || true
    done
  fi
  if [ "$KEEP_ON_EXIT" != "1" ]; then
    if [ -n "${SM_BACKUP_FILE:-}" ] && [ -f "${SM_BACKUP_FILE:-}" ]; then
      rm -f "$SM_BACKUP_FILE" >/dev/null 2>&1 || true
    fi
  fi
}

trap cleanup EXIT

register_restore() {
  RESTORE_ACTIONS+=("$*")
}

start_prom_port_forward() {
  PROM_PORT="$(pick_free_port)"
  kubectl -n "$PROM_NAMESPACE" port-forward "svc/$PROM_SERVICE" "$PROM_PORT":9090 >/dev/null 2>&1 &
  PF_PID=$!
}

wait_for_prometheus() {
  local attempt=0
  while [ $attempt -lt 30 ]; do
    if ! kill -0 "$PF_PID" >/dev/null 2>&1; then
      echo "ERROR: Prometheus port-forward process died" >&2
      return 1
    fi
    if curl -fsS "http://127.0.0.1:$PROM_PORT/-/ready" >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  echo "ERROR: Prometheus port-forward not ready" >&2
  return 1
}

start_alertmanager_port_forward() {
  ALERT_PORT="$(pick_free_port)"
  kubectl -n "$ALERTMANAGER_NAMESPACE" port-forward "svc/$ALERTMANAGER_SERVICE" "$ALERT_PORT":9093 >/dev/null 2>&1 &
  ALERT_PF_PID=$!
}

wait_for_alertmanager() {
  local attempt=0
  while [ $attempt -lt 30 ]; do
    if ! kill -0 "$ALERT_PF_PID" >/dev/null 2>&1; then
      echo "ERROR: Alertmanager port-forward process died" >&2
      return 1
    fi
    if curl -fsS "http://127.0.0.1:$ALERT_PORT/api/v2/status" >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  echo "ERROR: Alertmanager port-forward not ready" >&2
  return 1
}

alertmanager_firing_alertnames() {
  local resp
  resp=$(curl -fsS "http://127.0.0.1:$ALERT_PORT/api/v2/alerts" || echo '[]')
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
  # Treat both as "present/firing-equivalent" for chaos validation.
  if alert.get("status", {}).get("state") not in ("active", "suppressed"):
    continue
  name = (alert.get("labels") or {}).get("alertname")
  if name:
    names.append(name)

sys.stdout.write("\n".join(sorted(set(names))))
' <<<"$resp"
}

alertmanager_find_alert() {
  local alert_name="$1"
  local resp
  resp=$(curl -fsS "http://127.0.0.1:$ALERT_PORT/api/v2/alerts" || echo '[]')
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
  status = alert.get("status", {})
  sys.stdout.write(json.dumps({
    "state": status.get("state"),
    "startsAt": alert.get("startsAt"),
  }))
  sys.exit(0)

sys.stdout.write("{}")
' <<<"$resp"
}

epoch_from_rfc3339() {
  local ts="$1"
  TS="$ts" python3 - <<'PY'
import os
from datetime import datetime, timezone

ts = os.environ.get("TS", "")
try:
  dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
  if dt.tzinfo is None:
    dt = dt.replace(tzinfo=timezone.utc)
  print(int(dt.timestamp()))
except Exception:
  print("")
PY
}

wait_for_rule_loaded() {
  local alert_name="$1"
  local timeout_seconds="$2"
  local deadline
  deadline=$(( $(date +%s) + timeout_seconds ))

  while [ "$(date +%s)" -lt "$deadline" ]; do
    raw=$(curl -fsS "http://127.0.0.1:$PROM_PORT/api/v1/rules" || echo "")
    if [ -n "$raw" ]; then
      found=$(ALERT_NAME="$alert_name" python3 -c '
import json
import os
import sys

target = os.environ.get("ALERT_NAME", "")
raw = sys.stdin.read().strip()
if not raw:
  sys.stdout.write("0")
  sys.exit(0)

try:
  data = json.loads(raw)
except Exception:
  sys.stdout.write("0")
  sys.exit(0)

groups = (data.get("data") or {}).get("groups") or []
for g in groups:
  for r in g.get("rules") or []:
    if r.get("type") != "alerting":
      continue
    if r.get("name") == target:
      sys.stdout.write("1")
      sys.exit(0)

sys.stdout.write("0")
' <<<"$raw")
      if [ "$found" = "1" ]; then
        return 0
      fi
    fi
    sleep 2
  done

  echo "ERROR: Prometheus did not have expected alerting rule loaded within ${timeout_seconds}s: ${alert_name}" >&2
  return 1
}

wait_for_expected_alert() {
  local expected_csv="$1"
  local baseline_csv="$2"
  local max_detect="$3"
  local t0_epoch="$4"

  local expected_list
  expected_list=$(echo "$expected_csv" | tr ',' ' ')

  local deadline
  deadline=$((t0_epoch + max_detect))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    current_csv=$(alertmanager_firing_alertnames | tr '\n' ',' | sed 's/,$//')
    unexpected=$(python3 - <<PY
baseline = set(filter(None, "${baseline_csv}".split(",")))
current = set(filter(None, "${current_csv}".split(",")))
expected = set(filter(None, "${expected_csv}".split(",")))
unexpected = sorted(current - baseline - expected)
print(",".join(unexpected))
PY
)
    if [ -n "$unexpected" ]; then
      echo "ERROR: unrelated alerts fired during chaos: $unexpected" >&2
      return 1
    fi

    for name in $expected_list; do
      info=$(alertmanager_find_alert "$name")
      state=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("state",""))' <<<"$info")
      if [ "$state" = "active" ] || [ "$state" = "suppressed" ]; then
        starts_at=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("startsAt",""))' <<<"$info")
        echo "$starts_at"
        return 0
      fi
    done
    sleep 2
  done
  return 1
}

wait_for_alert_clear() {
  local expected="$1"
  local max_clear="$2"
  local fired_epoch="$3"
  local baseline_csv="$4"

  local deadline
  deadline=$((fired_epoch + max_clear))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    current_csv=$(alertmanager_firing_alertnames | tr '\n' ',' | sed 's/,$//')
    unexpected=$(python3 - <<PY
baseline = set(filter(None, "${baseline_csv}".split(",")))
current = set(filter(None, "${current_csv}".split(",")))
expected = {"${expected}"}
unexpected = sorted(current - baseline - expected)
print(",".join(unexpected))
PY
)
    if [ -n "$unexpected" ]; then
      echo "ERROR: unrelated alerts still firing during recovery: $unexpected" >&2
      return 1
    fi

    info=$(alertmanager_find_alert "$expected")
    state=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("state",""))' <<<"$info")
    if [ -z "$state" ] || { [ "$state" != "active" ] && [ "$state" != "suppressed" ]; }; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_alerts_clear() {
  local expected_csv="$1"
  local max_clear="$2"
  local fired_epoch="$3"
  local baseline_csv="$4"

  local expected_list
  expected_list=$(echo "$expected_csv" | tr ',' ' ')

  local deadline
  deadline=$((fired_epoch + max_clear))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    current_csv=$(alertmanager_firing_alertnames | tr '\n' ',' | sed 's/,$//')
    unexpected=$(python3 - <<PY
baseline = set(filter(None, "${baseline_csv}".split(",")))
current = set(filter(None, "${current_csv}".split(",")))
expected = set(filter(None, "${expected_csv}".split(",")))
unexpected = sorted(current - baseline - expected)
print(",".join(unexpected))
PY
)
    if [ -n "$unexpected" ]; then
      echo "ERROR: unrelated alerts still firing during recovery: $unexpected" >&2
      return 1
    fi

    any_active=0
    for name in $expected_list; do
      info=$(alertmanager_find_alert "$name")
      state=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("state",""))' <<<"$info")
      if [ "$state" = "active" ] || [ "$state" = "suppressed" ]; then
        any_active=1
        break
      fi
    done
    if [ "$any_active" = "0" ]; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      return 0
    fi
    sleep 2
  done
  return 1
}

run_validation_job_once() {
  kubectl -n "$NAMESPACE_THREADFORGE" delete job threadforge-observability-diagnostic --ignore-not-found --wait=false >/dev/null
  kubectl apply -f "$JOB_FILE" >/dev/null
  kubectl -n "$NAMESPACE_THREADFORGE" wait --for=condition=complete job/threadforge-observability-diagnostic --timeout=180s >/dev/null
}

append_result() {
  local mode="$1"
  local alert_name="$2"
  local failure_start_utc="$3"
  local fired_utc="$4"
  local detection_latency="$5"
  local cleared_utc="$6"
  local recovery_latency="$7"

  mkdir -p "$(dirname "$OUT_FILE")"
  {
    echo "mode: $mode"
    echo "alert_name: $alert_name"
    echo "failure_start_utc: $failure_start_utc"
    echo "alert_fired_utc: $fired_utc"
    echo "detection_latency_seconds: $detection_latency"
    echo "alert_cleared_utc: $cleared_utc"
    echo "recovery_latency_seconds: $recovery_latency"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "---"
  } >>"$OUT_FILE"
}

do_mode_smp() {
  local mode="smp"
  local expected_csv="SMPQueuePressureHigh,SMPDispatcherStall,ThreadforgeApiScrapeMissing"
  local max_detect="$MAX_DETECTION_SECONDS_DEFAULT"

  echo "[chaos] mode=${mode} inject=scale_api_to_zero detect<=${max_detect}s clear<=${MAX_CLEAR_SECONDS}s" >&2

  wait_for_rule_loaded "SMPQueuePressureHigh" 180
  wait_for_rule_loaded "SMPDispatcherStall" 180

  replicas=$(kubectl -n "$NAMESPACE_THREADFORGE" get deploy threadforge-api -o jsonpath='{.spec.replicas}')
  register_restore "kubectl -n $NAMESPACE_THREADFORGE scale deploy threadforge-api --replicas=${replicas}"

  kubectl -n "$NAMESPACE_THREADFORGE" scale deploy threadforge-api --replicas=0 >/dev/null
  # Ensure the failure condition is actually in effect before starting the SLA timer.
  kubectl -n "$NAMESPACE_THREADFORGE" rollout status deploy/threadforge-api --timeout=180s >/dev/null || true
  failure_start_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  t0_epoch=$(date +%s)

  fired_time=$(wait_for_expected_alert "$expected_csv" "$baseline_csv" "$max_detect" "$t0_epoch") || {
    echo "ERROR: expected SMP alert did not fire within ${max_detect}s: $expected_csv" >&2
    return 1
  }
  echo "[chaos] mode=${mode} detected alerts=${expected_csv}" >&2
  fired_epoch=$(epoch_from_rfc3339 "$fired_time")
  if [ -z "$fired_epoch" ]; then
    fired_epoch=$(date +%s)
  fi
  detection_latency=$((fired_epoch - t0_epoch))

  kubectl -n "$NAMESPACE_THREADFORGE" scale deploy threadforge-api --replicas="${replicas}" >/dev/null
  kubectl -n "$NAMESPACE_THREADFORGE" rollout status deploy/threadforge-api --timeout=180s >/dev/null

  cleared_time=$(wait_for_alerts_clear "$expected_csv" "$MAX_CLEAR_SECONDS" "$fired_epoch" "$baseline_csv") || {
    echo "ERROR: expected alerts did not all clear within ${MAX_CLEAR_SECONDS}s: $expected_csv" >&2
    return 1
  }
  echo "[chaos] mode=${mode} recovered (all expected alerts cleared)" >&2
  cleared_epoch=$(epoch_from_rfc3339 "$cleared_time")
  if [ -z "$cleared_epoch" ]; then
    cleared_epoch=$(date +%s)
  fi
  recovery_latency=$((cleared_epoch - fired_epoch))

  sleep "$POST_WAIT_SECONDS"
  append_result "$mode" "$expected_csv" "$failure_start_utc" "$fired_time" "$detection_latency" "$cleared_time" "$recovery_latency"
}

do_mode_ledger() {
  local mode="ledger"
  local expected="OperatorLedgerDBFailures"
  local max_detect="$MAX_DETECTION_SECONDS_DEFAULT"

  echo "[chaos] mode=${mode} inject=scale_postgres_to_zero detect<=${max_detect}s clear<=${MAX_CLEAR_SECONDS}s" >&2

  wait_for_rule_loaded "$expected" 180

  replicas=$(kubectl -n threadforge-system get sts postgres -o jsonpath='{.spec.replicas}')
  register_restore "kubectl -n threadforge-system scale sts postgres --replicas=${replicas}"

  failure_start_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  t0_epoch=$(date +%s)
  kubectl -n threadforge-system scale sts postgres --replicas=0 >/dev/null

  run_validation_job_once || true

  fired_time=$(wait_for_expected_alert "$expected" "$baseline_csv" "$max_detect" "$t0_epoch") || {
    echo "ERROR: expected alert did not fire within ${max_detect}s: $expected" >&2
    return 1
  }
  echo "[chaos] mode=${mode} detected alert=${expected}" >&2
  fired_epoch=$(epoch_from_rfc3339 "$fired_time")
  if [ -z "$fired_epoch" ]; then
    fired_epoch=$(date +%s)
  fi
  detection_latency=$((fired_epoch - t0_epoch))

  kubectl -n threadforge-system scale sts postgres --replicas="${replicas}" >/dev/null
  kubectl -n threadforge-system rollout status sts/postgres --timeout=180s >/dev/null
  run_validation_job_once || true

  cleared_time=$(wait_for_alert_clear "$expected" "$MAX_CLEAR_SECONDS" "$fired_epoch" "$baseline_csv") || {
    echo "ERROR: expected alert did not clear within ${MAX_CLEAR_SECONDS}s: $expected" >&2
    return 1
  }
  echo "[chaos] mode=${mode} recovered (alert cleared)" >&2
  cleared_epoch=$(epoch_from_rfc3339 "$cleared_time")
  if [ -z "$cleared_epoch" ]; then
    cleared_epoch=$(date +%s)
  fi
  recovery_latency=$((cleared_epoch - fired_epoch))

  sleep "$POST_WAIT_SECONDS"
  append_result "$mode" "$expected" "$failure_start_utc" "$fired_time" "$detection_latency" "$cleared_time" "$recovery_latency"
}

do_mode_identity() {
  local mode="identity"
  local expected="IdentityCoverageLost"
  local max_detect="$MAX_DETECTION_SECONDS_IDENTITY"

  echo "[chaos] mode=${mode} inject=spiffe_down detect<=${max_detect}s clear<=${MAX_CLEAR_SECONDS}s" >&2

  wait_for_rule_loaded "$expected" 180

  spire_replicas=$(kubectl -n spire-system get sts spire-server -o jsonpath='{.spec.replicas}')
  register_restore "kubectl -n spire-system scale sts spire-server --replicas=${spire_replicas}"

  api_pod=$(kubectl -n "$NAMESPACE_THREADFORGE" get pods -l app=threadforge-api -o jsonpath='{.items[0].metadata.name}')
  api_node=$(kubectl -n "$NAMESPACE_THREADFORGE" get pod "$api_pod" -o jsonpath='{.spec.nodeName}')
  agent_pod=$(kubectl -n spire-system get pods -l app=spire-agent -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' | awk -v n="$api_node" '$2==n{print $1; exit}')
  if [ -z "$agent_pod" ]; then
    echo "ERROR: could not locate spire-agent pod on node $api_node" >&2
    return 1
  fi

  register_restore "kubectl -n spire-system delete pod ${agent_pod} --ignore-not-found"

  failure_start_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  t0_epoch=$(date +%s)

  kubectl -n spire-system scale sts spire-server --replicas=0 >/dev/null
  kubectl -n spire-system delete pod "$agent_pod" --wait=false >/dev/null
  kubectl -n "$NAMESPACE_THREADFORGE" rollout restart deploy/threadforge-api >/dev/null
  kubectl -n "$NAMESPACE_THREADFORGE" rollout status deploy/threadforge-api --timeout=180s >/dev/null

  fired_time=$(wait_for_expected_alert "$expected" "$baseline_csv" "$max_detect" "$t0_epoch") || {
    echo "ERROR: expected alert did not fire within ${max_detect}s: $expected" >&2
    return 1
  }
  echo "[chaos] mode=${mode} detected alert=${expected}" >&2
  fired_epoch=$(epoch_from_rfc3339 "$fired_time")
  if [ -z "$fired_epoch" ]; then
    fired_epoch=$(date +%s)
  fi
  detection_latency=$((fired_epoch - t0_epoch))

  kubectl -n spire-system scale sts spire-server --replicas="$spire_replicas" >/dev/null
  kubectl -n spire-system rollout status sts/spire-server --timeout=300s >/dev/null
  kubectl -n "$NAMESPACE_THREADFORGE" rollout restart deploy/threadforge-api >/dev/null
  kubectl -n "$NAMESPACE_THREADFORGE" rollout status deploy/threadforge-api --timeout=180s >/dev/null

  cleared_time=$(wait_for_alert_clear "$expected" "$MAX_CLEAR_SECONDS" "$fired_epoch" "$baseline_csv") || {
    echo "ERROR: expected alert did not clear within ${MAX_CLEAR_SECONDS}s: $expected" >&2
    return 1
  }
  echo "[chaos] mode=${mode} recovered (alert cleared)" >&2
  cleared_epoch=$(epoch_from_rfc3339 "$cleared_time")
  if [ -z "$cleared_epoch" ]; then
    cleared_epoch=$(date +%s)
  fi
  recovery_latency=$((cleared_epoch - fired_epoch))

  sleep "$POST_WAIT_SECONDS"
  append_result "$mode" "$expected" "$failure_start_utc" "$fired_time" "$detection_latency" "$cleared_time" "$recovery_latency"
}

do_mode_scrape() {
  local mode="scrape"
  local expected="ThreadforgeApiScrapeMissing"
  local max_detect="$MAX_DETECTION_SECONDS_DEFAULT"

  echo "[chaos] mode=${mode} inject=scrape_probe_label_toggle detect<=${max_detect}s clear<=${MAX_CLEAR_SECONDS}s" >&2

  wait_for_rule_loaded "$expected" 180

  # Inject scrape disappearance without disrupting primary scraping/alerts.
  # Toggle ONLY the dedicated scrape-probe label used by the `threadforge-api-scrape-probe`
  # ServiceMonitor so unrelated subsystem alerts do not fire.
  probe_label_value=$(kubectl -n "$NAMESPACE_THREADFORGE" get svc threadforge-api -o jsonpath='{.metadata.labels.threadforge\.chaos/scrape-probe}' 2>/dev/null || true)
  if [ -n "$probe_label_value" ]; then
    register_restore "kubectl -n $NAMESPACE_THREADFORGE label svc threadforge-api threadforge.chaos/scrape-probe=${probe_label_value} --overwrite"
  else
    register_restore "kubectl -n $NAMESPACE_THREADFORGE label svc threadforge-api threadforge.chaos/scrape-probe=true --overwrite"
  fi

  kubectl -n "$NAMESPACE_THREADFORGE" label svc threadforge-api threadforge.chaos/scrape-probe- >/dev/null

  # Ensure the failure condition is actually in effect before starting the SLA timer.
  local attempt=0
  while [ $attempt -lt 60 ]; do
    absent_count=$(curl -fsS --get --data-urlencode 'query=absent_over_time(up{job="threadforge-scrape-probe"}[20s])' "http://127.0.0.1:$PROM_PORT/api/v1/query" | \
      python3 -c 'import json,sys; j=json.load(sys.stdin); print(len((j.get("data") or {}).get("result") or []))' || echo "")
    if [ "$absent_count" != "" ] && [ "$absent_count" != "0" ]; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  if [ "$absent_count" = "" ] || [ "$absent_count" = "0" ]; then
    echo "ERROR: expected absence condition did not become true after toggling Service label" >&2
    return 1
  fi

  failure_start_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  t0_epoch=$(date +%s)

  fired_time=$(wait_for_expected_alert "$expected" "$baseline_csv" "$max_detect" "$t0_epoch") || {
    echo "ERROR: expected alert did not fire within ${max_detect}s: $expected" >&2
    return 1
  }
  echo "[chaos] mode=${mode} detected alert=${expected}" >&2
  fired_epoch=$(epoch_from_rfc3339 "$fired_time")
  if [ -z "$fired_epoch" ]; then
    fired_epoch=$(date +%s)
  fi
  detection_latency=$((fired_epoch - t0_epoch))

  # Restore the probe label immediately after observing the alert.
  if [ -n "$probe_label_value" ]; then
    kubectl -n "$NAMESPACE_THREADFORGE" label svc threadforge-api threadforge.chaos/scrape-probe="$probe_label_value" --overwrite >/dev/null
  else
    kubectl -n "$NAMESPACE_THREADFORGE" label svc threadforge-api threadforge.chaos/scrape-probe=true --overwrite >/dev/null
  fi

  cleared_time=$(wait_for_alert_clear "$expected" "$MAX_CLEAR_SECONDS" "$fired_epoch" "$baseline_csv") || {
    echo "ERROR: expected alert did not clear within ${MAX_CLEAR_SECONDS}s: $expected" >&2
    return 1
  }
  echo "[chaos] mode=${mode} recovered (alert cleared)" >&2
  cleared_epoch=$(epoch_from_rfc3339 "$cleared_time")
  if [ -z "$cleared_epoch" ]; then
    cleared_epoch=$(date +%s)
  fi
  recovery_latency=$((cleared_epoch - fired_epoch))

  sleep "$POST_WAIT_SECONDS"
  append_result "$mode" "$expected" "$failure_start_utc" "$fired_time" "$detection_latency" "$cleared_time" "$recovery_latency"
}

main() {
  echo "[chaos] starting Level 7 chaos validation (this typically takes ~10–20 minutes)" >&2
  start_prom_port_forward
  wait_for_prometheus
  start_alertmanager_port_forward
  wait_for_alertmanager

  baseline_csv=$(alertmanager_firing_alertnames | tr '\n' ',' | sed 's/,$//')

  : >"$OUT_FILE"
  {
    echo "THREADFORGE LEVEL 7 CHAOS ALERT TIMING MATRIX"
    echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "baseline_firing_alerts_csv: ${baseline_csv:-none}"
    echo "MAX_DETECTION_SECONDS_DEFAULT: $MAX_DETECTION_SECONDS_DEFAULT"
    echo "MAX_DETECTION_SECONDS_IDENTITY: $MAX_DETECTION_SECONDS_IDENTITY"
    echo "MAX_CLEAR_SECONDS: $MAX_CLEAR_SECONDS"
    echo "---"
  } >>"$OUT_FILE"

  modes=(smp ledger identity scrape)
  if [ -n "$FAILURE_MODE" ]; then
    modes=("$FAILURE_MODE")
  fi

  for mode in "${modes[@]}"; do
    case "$mode" in
      smp) do_mode_smp ;;
      ledger) do_mode_ledger ;;
      identity) do_mode_identity ;;
      scrape) do_mode_scrape ;;
      *)
        echo "ERROR: --failure must be one of: smp, ledger, identity, scrape" >&2
        echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
        ;;
    esac
  done

  echo "Wrote chaos timing matrix: $OUT_FILE"
}

main
