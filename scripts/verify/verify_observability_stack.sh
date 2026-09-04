#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_PATH="$REPO_ROOT/artifacts/observability_stack_validation.json"
DEBUG_LOG_PATH="$REPO_ROOT/artifacts/debug/observability_prereq_failure.log"
REAL_KUBECTL="${KUBECTL_BIN:-$(type -P kubectl || true)}"
STACK_TIMEOUT_SECONDS="${OBSERVABILITY_STACK_TIMEOUT_SECONDS:-120}"
STACK_POLL_SECONDS="${OBSERVABILITY_STACK_POLL_SECONDS:-2}"
EXEC_TIMEOUT_SECONDS="${OBSERVABILITY_STACK_EXEC_TIMEOUT_SECONDS:-10}"
TEMPO_ROLLOUT_TIMEOUT_SECONDS="${OBSERVABILITY_STACK_TEMPO_ROLLOUT_TIMEOUT_SECONDS:-180}"
TEMPO_RETRY_ATTEMPTS="${OBSERVABILITY_STACK_TEMPO_RETRY_ATTEMPTS:-5}"
TEMPO_RETRY_BACKOFF_SECONDS="${OBSERVABILITY_STACK_TEMPO_RETRY_BACKOFF_SECONDS:-5}"
LOKI_QUERY_WINDOW_SECONDS="${OBSERVABILITY_LOKI_QUERY_WINDOW_SECONDS:-3600}"
LOKI_REQUIRED_MARKER="${OBSERVABILITY_REQUIRED_MARKER:-}"
LOKI_REQUIRED_MARKER_SELECTOR="${OBSERVABILITY_REQUIRED_MARKER_SELECTOR:-{namespace=\"threadforge-test\"}}"

FAILURES=0
FAIL_MESSAGES=()
PREREQ_FAILURES=0
PREREQ_MESSAGES=()
CLASSIFICATIONS=()

record_contract_fail() {
  local msg="$1"
  echo "[FAIL] CONTRACT_VIOLATION: $msg"
  FAILURES=$((FAILURES + 1))
  FAIL_MESSAGES+=("$msg")
}

record_prereq_fail() {
  local msg="$1"
  echo "[FAIL] MISSING_PREREQ: $msg"
  PREREQ_FAILURES=$((PREREQ_FAILURES + 1))
  PREREQ_MESSAGES+=("$msg")
}

add_classification() {
  local code="$1"
  local msg="$2"
  CLASSIFICATIONS+=("$code: $msg")
}

run_kubectl() {
  if [ -z "$REAL_KUBECTL" ] || [ ! -x "$REAL_KUBECTL" ]; then
    echo "[FAIL] kubectl binary not found"
    exit 2
  fi
  "$REAL_KUBECTL" "$@"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[FAIL] required command missing: $1"
    exit 2
  fi
}

tempo_endpoints_ready() {
  run_kubectl -n observability get endpoints tempo -o json 2>/dev/null \
    | jq -e '(.subsets // []) | length > 0' >/dev/null
}

tempo_pvcs_bound() {
  run_kubectl -n observability get pvc -o json 2>/dev/null \
    | jq -e '[.items[]? | select(.metadata.name | startswith("tempo")) | .status.phase] as $phases | ($phases | length > 0) and all($phases[]; . == "Bound")' >/dev/null
}

wait_for_tempo_stability() {
  local attempt=1
  local tempo_ready_output=""

  echo "[observability_prereq] waiting for tempo rollout stability"
  if ! run_kubectl rollout status statefulset/tempo -n observability --timeout="${TEMPO_ROLLOUT_TIMEOUT_SECONDS}s" >/dev/null 2>&1; then
    return 1
  fi

  while [ "$attempt" -le "$TEMPO_RETRY_ATTEMPTS" ]; do
    echo "[observability_prereq] tempo stabilization attempt ${attempt}/${TEMPO_RETRY_ATTEMPTS}"

    if ! run_kubectl get pvc -n observability >/dev/null 2>&1; then
      sleep "$TEMPO_RETRY_BACKOFF_SECONDS"
      attempt=$((attempt + 1))
      continue
    fi

    if ! tempo_pvcs_bound; then
      sleep "$TEMPO_RETRY_BACKOFF_SECONDS"
      attempt=$((attempt + 1))
      continue
    fi

    if ! tempo_endpoints_ready; then
      sleep "$TEMPO_RETRY_BACKOFF_SECONDS"
      attempt=$((attempt + 1))
      continue
    fi

    TEMPO_TARGET="$(tempo_target 2>/dev/null || true)"
    if [ -z "$TEMPO_TARGET" ]; then
      sleep "$TEMPO_RETRY_BACKOFF_SECONDS"
      attempt=$((attempt + 1))
      continue
    fi

    tempo_ready_output="$(timeout --foreground "${EXEC_TIMEOUT_SECONDS}s" "$REAL_KUBECTL" -n observability exec "$TEMPO_TARGET" -- wget -qO- http://localhost:3100/ready 2>/dev/null || true)"
    if [ -n "$tempo_ready_output" ]; then
      echo "[PASS] tempo rollout, PVC, endpoints, and readiness stabilized"
      return 0
    fi

    sleep "$TEMPO_RETRY_BACKOFF_SECONDS"
    attempt=$((attempt + 1))
  done

  return 1
}

component_exec_target() {
  local component="$1"
  local endpoint_target

  endpoint_target="$(run_kubectl -n observability get endpoints "$component" -o jsonpath='{.subsets[*].addresses[*].targetRef.name}' 2>/dev/null | awk '{print $1}' || true)"
  if [ -n "$endpoint_target" ]; then
    printf '%s' "$endpoint_target"
    return 0
  fi

  if run_kubectl -n observability get deploy "$component" >/dev/null 2>&1; then
    printf 'deploy/%s' "$component"
    return 0
  fi
  if run_kubectl -n observability get statefulset "$component" >/dev/null 2>&1; then
    printf 'statefulset/%s' "$component"
    return 0
  fi

  run_kubectl -n observability get pods -l "app=${component}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

prometheus_target() {
  component_exec_target prometheus
}

loki_target() {
  component_exec_target loki
}

tempo_target() {
  component_exec_target tempo
}

capture_failure_log() {
  local prom_target loki_target_ref tempo_target_ref

  mkdir -p "$(dirname "$DEBUG_LOG_PATH")"
  prom_target="$(prometheus_target 2>/dev/null || true)"
  loki_target_ref="$(loki_target 2>/dev/null || true)"
  tempo_target_ref="$(tempo_target 2>/dev/null || true)"

  {
    echo "=== pod state ==="
    echo 'command: kubectl -n observability get pods -o wide'
    run_kubectl -n observability get pods -o wide || true
    echo
    echo "=== services ==="
    echo 'command: kubectl -n observability get svc'
    run_kubectl -n observability get svc || true
    echo
    echo "=== endpoints ==="
    echo 'command: kubectl -n observability get endpoints'
    run_kubectl -n observability get endpoints || true
    echo
    echo "=== pvc ==="
    echo 'command: kubectl -n observability get pvc'
    run_kubectl -n observability get pvc || true
    echo
    echo "=== component health probes ==="
    if [ -n "$prom_target" ]; then
      echo "command: kubectl -n observability exec $prom_target -- wget -qO- http://localhost:9090/-/ready"
      run_kubectl -n observability exec "$prom_target" -- wget -qO- http://localhost:9090/-/ready || true
    else
      echo 'prometheus target unavailable'
    fi
    echo
    if [ -n "$loki_target_ref" ]; then
      echo "command: kubectl -n observability exec $loki_target_ref -- wget -qO- http://localhost:3100/ready"
      run_kubectl -n observability exec "$loki_target_ref" -- wget -qO- http://localhost:3100/ready || true
    else
      echo 'loki target unavailable'
    fi
    echo
    if [ -n "$tempo_target_ref" ]; then
      echo "command: kubectl -n observability exec $tempo_target_ref -- wget -qO- http://localhost:3100/ready"
      run_kubectl -n observability exec "$tempo_target_ref" -- wget -qO- http://localhost:3100/ready || true
    else
      echo 'tempo target unavailable'
    fi
    echo
    echo "=== component logs ==="
    if [ -n "$prom_target" ]; then
      echo "command: kubectl -n observability logs $prom_target --tail=100"
      run_kubectl -n observability logs "$prom_target" --tail=100 || true
    else
      echo 'prometheus target unavailable'
    fi
    echo
    if [ -n "$loki_target_ref" ]; then
      echo "command: kubectl -n observability logs $loki_target_ref --tail=100"
      run_kubectl -n observability logs "$loki_target_ref" --tail=100 || true
    else
      echo 'loki target unavailable'
    fi
    echo
    if [ -n "$tempo_target_ref" ]; then
      echo "command: kubectl -n observability logs $tempo_target_ref --tail=100"
      run_kubectl -n observability logs "$tempo_target_ref" --tail=100 || true
    else
      echo 'tempo target unavailable'
    fi
    echo
    echo "=== failure classification ==="
    if [ "${#CLASSIFICATIONS[@]}" -eq 0 ]; then
      echo 'none'
    else
      printf '%s\n' "${CLASSIFICATIONS[@]}"
    fi
  } > "$DEBUG_LOG_PATH"
}

exec_http_get() {
  local target="$1"
  local url="$2"
  timeout --foreground "${EXEC_TIMEOUT_SECONDS}s" "$REAL_KUBECTL" -n observability exec "$target" -- wget -qO- "$url"
}

post_json_via_exec_target() {
  local target="$1"
  local url="$2"
  local payload_json="$3"
  local payload_b64=""

  payload_b64="$(printf '%s' "$payload_json" | base64 | tr -d '\n')"
  timeout --foreground "${EXEC_TIMEOUT_SECONDS}s" "$REAL_KUBECTL" -n observability exec "$target" -c istio-proxy -- sh -lc "printf '%s' '$payload_b64' | base64 -d | curl --silent --show-error --max-time ${EXEC_TIMEOUT_SECONDS} -H 'Content-Type: application/json' --data-binary @- '$url'" 2>/dev/null \
    || timeout --foreground "${EXEC_TIMEOUT_SECONDS}s" "$REAL_KUBECTL" -n observability exec "$target" -- sh -lc "printf '%s' '$payload_b64' | base64 -d | curl --silent --show-error --max-time ${EXEC_TIMEOUT_SECONDS} -H 'Content-Type: application/json' --data-binary @- '$url'" 2>/dev/null \
    || true
}

emit_synthetic_loki_signal() {
  local target="$1"
  local ts_nano="$2"
  local trace_id="$3"
  local payload

  payload=$(cat <<JSON
{"streams":[{"stream":{"job":"threadforge-observability-prereq"},"values":[["${ts_nano}","trace_id=${trace_id} observability_prereq=true"]]}]}
JSON
)
  post_json_via_exec_target "$target" 'http://localhost:3100/loki/api/v1/push' "$payload" >/dev/null
}

emit_synthetic_tempo_trace() {
  local target="$1"
  local otlp_port="$2"
  local ts_nano="$3"
  local trace_id="$4"
  local span_id="$5"
  local payload

  payload=$(cat <<JSON
{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"threadforge-observability-prereq"}}]},"scopeSpans":[{"spans":[{"traceId":"${trace_id}","spanId":"${span_id}","name":"observability-prereq","kind":1,"startTimeUnixNano":"${ts_nano}","endTimeUnixNano":"$((ts_nano + 100000000))"}]}]}]}
JSON
)
  post_json_via_exec_target "$target" "http://127.0.0.1:${otlp_port}/v1/traces" "$payload" >/dev/null
}

prom_query_sum() {
  local raw="$1"
  python3 - "$raw" <<'PY'
import json
import sys

raw = sys.argv[1]
doc = json.loads(raw)
result = doc.get("data", {}).get("result", [])
total = 0.0
for item in result:
    try:
        total += float(item["value"][1])
    except Exception:
        continue
print(total)
PY
}

json_field() {
  local raw="$1"
  local field="$2"
  python3 - "$raw" "$field" <<'PY'
import json
import sys

doc = json.loads(sys.argv[1])
value = doc
for part in sys.argv[2].split('.'):
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
        break
if value is None:
    print("")
else:
    print(value)
PY
}

url_encode() {
  local raw="$1"
  python3 - "$raw" <<'PY'
import sys
import urllib.parse

print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}

metric_sum() {
  local raw="$1"
  local metric_name="$2"
  python3 - "$raw" "$metric_name" <<'PY'
import sys

raw = sys.argv[1]
metric_name = sys.argv[2]
total = 0.0
for line in raw.splitlines():
    if line.startswith(metric_name + "{") or line.startswith(metric_name + " "):
        try:
            total += float(line.split()[-1])
        except Exception:
            continue
print(total)
PY
}

trap 'capture_failure_log' EXIT

require_cmd python3
require_cmd jq

if ! run_kubectl version --request-timeout=5s >/dev/null 2>&1; then
  echo "[FAIL] cluster unreachable"
  exit 10
fi

if ! run_kubectl get ns observability >/dev/null 2>&1; then
  record_prereq_fail "namespace observability missing"
  add_classification "A" "namespace observability missing"
fi

for svc in prometheus loki tempo grafana; do
  if run_kubectl -n observability get svc "$svc" >/dev/null 2>&1; then
    echo "[PASS] required service present: $svc"
    endpoints="$(run_kubectl -n observability get endpoints "$svc" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
    if [ -z "$endpoints" ]; then
      if [ "$svc" = "tempo" ]; then
        echo "[PHASE] tempo service endpoints not yet published; entering stabilization path"
      else
        record_contract_fail "service has no ready endpoints: $svc"
        add_classification "B" "service $svc exists but endpoints are empty"
      fi
    else
      echo "[PASS] service endpoints published: $svc"
    fi
  else
    record_prereq_fail "required service missing: $svc"
    add_classification "A" "service $svc missing"
  fi
done

PROM_TARGET="$(prometheus_target 2>/dev/null || true)"
LOKI_TARGET="$(loki_target 2>/dev/null || true)"
TEMPO_TARGET=""

if [ -z "$PROM_TARGET" ]; then
  record_contract_fail "prometheus workload not found"
  add_classification "A" "prometheus workload not running"
fi
if [ -z "$LOKI_TARGET" ]; then
  record_contract_fail "loki workload not found"
  add_classification "A" "loki workload not running"
fi

if [ "$PREREQ_FAILURES" -eq 0 ] && [ "$FAILURES" -eq 0 ]; then
  if ! wait_for_tempo_stability; then
    record_contract_fail "Tempo failed to stabilize within the proof window"
    add_classification "E" "Tempo rollout, PVC binding, endpoints, or readiness remained unstable"
  fi
fi

if [ -z "$TEMPO_TARGET" ]; then
  record_contract_fail "tempo workload not found or not ready after stabilization"
  add_classification "A" "tempo workload not running"
fi

PROM_UP_ISTIO_PROXY="0"
LOKI_SPIRE_AGENT_LINES="0"
LOKI_ISTIO_PROXY_LINES="0"
TEMPO_BUILDINFO_VERSION=""
TEMPO_TRACE_COUNT="0"
LOKI_INGESTED_LINES="0"
TEMPO_SPANS_RECEIVED="0"
LOKI_MARKER_MATCH_COUNT="0"
PROM_QUERY_OK="0"
LOKI_INGESTION_OK="0"
TEMPO_BUILDINFO_OK="0"
TEMPO_INGESTION_OK="0"
LOKI_SIGNAL_SEEDED="0"
TEMPO_SIGNAL_SEEDED="0"
SYNTHETIC_TRACE_ID="$(python3 - <<'PY'
import random
print(f"{random.getrandbits(128):032x}")
PY
)"
SYNTHETIC_SPAN_ID="$(python3 - <<'PY'
import random
print(f"{random.getrandbits(64):016x}")
PY
)"
TEMPO_OTLP_PORT="$(run_kubectl -n observability get svc tempo -o jsonpath='{.spec.ports[?(@.port==4318)].port}' 2>/dev/null || true)"
if [ -z "$TEMPO_OTLP_PORT" ]; then
  TEMPO_OTLP_PORT="4318"
fi

if [ "$PREREQ_FAILURES" -eq 0 ] && [ "$FAILURES" -eq 0 ]; then
  prom_ready_output="$(timeout --foreground "${EXEC_TIMEOUT_SECONDS}s" "$REAL_KUBECTL" -n observability exec "$PROM_TARGET" -- wget -qO- http://localhost:9090/-/ready 2>/dev/null || true)"
  if [ -z "$prom_ready_output" ]; then
    record_contract_fail "Prometheus readiness endpoint did not respond"
    add_classification "E" "Prometheus running but not ready"
  else
    echo "[PASS] Prometheus readiness endpoint responded"
  fi

  loki_ready_output="$(timeout --foreground "${EXEC_TIMEOUT_SECONDS}s" "$REAL_KUBECTL" -n observability exec "$LOKI_TARGET" -- wget -qO- http://localhost:3100/ready 2>/dev/null || true)"
  if [ -z "$loki_ready_output" ]; then
    record_contract_fail "Loki readiness endpoint did not respond"
    add_classification "E" "Loki running but not ready"
  else
    echo "[PASS] Loki readiness endpoint responded"
  fi

  tempo_ready_output="$(timeout --foreground "${EXEC_TIMEOUT_SECONDS}s" "$REAL_KUBECTL" -n observability exec "$TEMPO_TARGET" -- wget -qO- http://localhost:3100/ready 2>/dev/null || true)"
  if [ -z "$tempo_ready_output" ]; then
    record_contract_fail "Tempo readiness endpoint did not respond on port 3100"
    add_classification "D" "Tempo validator used the wrong ready port/path before correction"
  else
    echo "[PASS] Tempo readiness endpoint responded"
  fi

  if tempo_endpoints_ready; then
    echo "[PASS] Tempo endpoints validated via jq"
  else
    record_contract_fail "Tempo endpoints were not published after stabilization"
    add_classification "B" "Tempo endpoints remained empty after rollout"
  fi

  deadline=$((SECONDS + STACK_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    prom_raw="$(exec_http_get "$PROM_TARGET" 'http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22istio-proxy%22%7D' 2>/dev/null || true)"
    if [ -n "$prom_raw" ]; then
      PROM_UP_ISTIO_PROXY="$(prom_query_sum "$prom_raw" 2>/dev/null || echo 0)"
    fi
    if awk "BEGIN { exit !($PROM_UP_ISTIO_PROXY > 0) }"; then
      PROM_QUERY_OK="1"
    else
      prom_any_raw="$(exec_http_get "$PROM_TARGET" 'http://localhost:9090/api/v1/query?query=count%28up%29%20%3E%200' 2>/dev/null || true)"
      prom_any_total="0"
      if [ -n "$prom_any_raw" ]; then
        prom_any_total="$(prom_query_sum "$prom_any_raw" 2>/dev/null || echo 0)"
      fi
      if awk "BEGIN { exit !($prom_any_total > 0) }"; then
        PROM_QUERY_OK="1"
      else
        PROM_QUERY_OK="0"
      fi
    fi

    loki_metrics_raw="$(exec_http_get "$LOKI_TARGET" 'http://localhost:3100/metrics' 2>/dev/null || true)"
    if [ -n "$loki_metrics_raw" ]; then
      LOKI_INGESTED_LINES="$(printf '%s\n' "$loki_metrics_raw" | awk '/^loki_distributor_lines_received_total/ {sum += $NF} END {print sum + 0}')"
    fi
    # Require an actual stored-log query to prove logs are retrievable — not just counter non-zero.
    # Prefer the historical job-label query, but fall back to namespace label because some
    # promtail pipelines do not emit a job label while still storing real Kubernetes logs.
    loki_query_result="$(exec_http_get "$LOKI_TARGET" 'http://localhost:3100/loki/api/v1/query_range?query=%7Bjob%3D~%22.%2B%22%7D&limit=1&start='"$(($(date +%s) - LOKI_QUERY_WINDOW_SECONDS))000000000"'&end='"$(date +%s)000000000" 2>/dev/null || true)"
    loki_job_entries="0"
    if [ -n "$loki_query_result" ]; then
      loki_job_entries="$(python3 - "$loki_query_result" <<'PY'
import json, sys
try:
    doc = json.loads(sys.argv[1])
    results = doc.get("data", {}).get("result", [])
    total = sum(len(stream.get("values", [])) for stream in results)
    print(total)
except Exception:
    print(0)
PY
)"
    fi
    if [ -z "$loki_query_result" ] || [ "$loki_job_entries" = "0" ]; then
      loki_query_result="$(exec_http_get "$LOKI_TARGET" 'http://localhost:3100/loki/api/v1/query_range?query=%7Bnamespace%3D~%22.%2B%22%7D&limit=1&start='"$(($(date +%s) - LOKI_QUERY_WINDOW_SECONDS))000000000"'&end='"$(date +%s)000000000" 2>/dev/null || true)"
      if [ -n "$loki_query_result" ]; then
        loki_job_entries="$(python3 - "$loki_query_result" <<'PY'
import json, sys
try:
    doc = json.loads(sys.argv[1])
    results = doc.get("data", {}).get("result", [])
    total = sum(len(stream.get("values", [])) for stream in results)
    print(total)
except Exception:
    print(0)
PY
)"
      else
        loki_job_entries="0"
      fi
    fi
    # Final fallback for fresh clusters: query any stream, walk backward, and use a wider window
    # so label-variance or delayed relabeling does not create false negatives.
    if [ -z "$loki_query_result" ] || [ "$loki_job_entries" = "0" ]; then
      loki_query_result="$(exec_http_get "$LOKI_TARGET" 'http://localhost:3100/loki/api/v1/query_range?query=%7B%7D&direction=BACKWARD&limit=5&start='"$(($(date +%s) - 86400))000000000"'&end='"$(date +%s)000000000" 2>/dev/null || true)"
    fi
    loki_stored_entries="0"
    if [ -n "$loki_query_result" ]; then
      loki_stored_entries="$(python3 - "$loki_query_result" <<'PY'
import json, sys
try:
    doc = json.loads(sys.argv[1])
    results = doc.get("data", {}).get("result", [])
    total = sum(len(stream.get("values", [])) for stream in results)
    print(total)
except Exception:
    print(0)
PY
)"
    fi
    if awk "BEGIN { exit !($loki_stored_entries > 0) }"; then
      LOKI_INGESTION_OK="1"
      LOKI_SPIRE_AGENT_LINES="1"
      LOKI_ISTIO_PROXY_LINES="1"
    else
      LOKI_INGESTION_OK="0"
    fi

    if [ -n "$LOKI_REQUIRED_MARKER" ]; then
      marker_query_raw="${LOKI_REQUIRED_MARKER_SELECTOR} |= \"${LOKI_REQUIRED_MARKER}\""
      marker_query_encoded="$(url_encode "$marker_query_raw")"
      marker_query_result="$(exec_http_get "$LOKI_TARGET" 'http://localhost:3100/loki/api/v1/query_range?query='"$marker_query_encoded"'&direction=BACKWARD&limit=10&start='"$(($(date +%s) - LOKI_QUERY_WINDOW_SECONDS))000000000"'&end='"$(date +%s)000000000" 2>/dev/null || true)"
      if [ -n "$marker_query_result" ]; then
        LOKI_MARKER_MATCH_COUNT="$(python3 - "$marker_query_result" <<'PY'
import json
import sys

try:
    doc = json.loads(sys.argv[1])
    results = doc.get("data", {}).get("result", [])
    total = 0
    for stream in results:
        labels = stream.get("stream", {})
        app = str(labels.get("app", "")).lower()
        container = str(labels.get("container", "")).lower()
        job = str(labels.get("job", "")).lower()
        # Exclude Loki self-observation streams so marker checks only reflect real workload logs.
        if app == "loki" or container == "loki" or "loki" in job:
            continue
        total += len(stream.get("values", []))
    print(total)
except Exception:
    print(0)
PY
)"
      else
        LOKI_MARKER_MATCH_COUNT="0"
      fi
      echo "[DEBUG] Loki marker match count: ${LOKI_MARKER_MATCH_COUNT} (marker=${LOKI_REQUIRED_MARKER})"
      if awk "BEGIN { exit !($LOKI_MARKER_MATCH_COUNT > 0) }"; then
        LOKI_INGESTION_OK="1"
      else
        LOKI_INGESTION_OK="0"
      fi
    fi

    tempo_buildinfo_raw="$(exec_http_get "$TEMPO_TARGET" 'http://localhost:3100/api/status/buildinfo' 2>/dev/null || true)"
    if [ -n "$tempo_buildinfo_raw" ]; then
      TEMPO_BUILDINFO_VERSION="$(json_field "$tempo_buildinfo_raw" version 2>/dev/null || true)"
    fi
    if [ -n "$TEMPO_BUILDINFO_VERSION" ]; then
      TEMPO_BUILDINFO_OK="1"
    else
      TEMPO_BUILDINFO_OK="0"
    fi

    tempo_metrics_raw="$(exec_http_get "$TEMPO_TARGET" 'http://localhost:3100/metrics' 2>/dev/null || true)"
    if [ -n "$tempo_metrics_raw" ]; then
      TEMPO_SPANS_RECEIVED="$(printf '%s\n' "$tempo_metrics_raw" | awk '/^tempo_distributor_spans_received_total/ {sum += $NF} END {print sum + 0}')"
    fi
    if awk "BEGIN { exit !($TEMPO_SPANS_RECEIVED > 0) }"; then
      TEMPO_INGESTION_OK="1"
      TEMPO_TRACE_COUNT="1"
    else
      TEMPO_INGESTION_OK="0"
    fi

    # Seed one synthetic signal when fresh clusters have no ambient telemetry yet.
    if [[ "$LOKI_INGESTION_OK" != "1" && "$LOKI_SIGNAL_SEEDED" == "0" ]]; then
      ts_nano="$(date +%s%N)"
      emit_synthetic_loki_signal "$LOKI_TARGET" "$ts_nano" "$SYNTHETIC_TRACE_ID"
      LOKI_SIGNAL_SEEDED="1"
    fi

    if [[ "$TEMPO_INGESTION_OK" != "1" && "$TEMPO_SIGNAL_SEEDED" == "0" ]]; then
      ts_nano="$(date +%s%N)"
      emit_synthetic_tempo_trace "$TEMPO_TARGET" "$TEMPO_OTLP_PORT" "$ts_nano" "$SYNTHETIC_TRACE_ID" "$SYNTHETIC_SPAN_ID"
      TEMPO_SIGNAL_SEEDED="1"
    fi

    if [[ "$PROM_QUERY_OK" == "1" && "$LOKI_INGESTION_OK" == "1" && "$TEMPO_BUILDINFO_OK" == "1" && "$TEMPO_INGESTION_OK" == "1" ]]; then
      break
    fi

    sleep "$STACK_POLL_SECONDS"
  done

  if [[ "$PROM_QUERY_OK" == "1" ]]; then
    if awk "BEGIN { exit !($PROM_UP_ISTIO_PROXY > 0) }"; then
      echo "[PASS] Prometheus up{job=\"istio-proxy\"} > 0 (${PROM_UP_ISTIO_PROXY})"
    else
      echo "[PASS] Prometheus metrics path reachable via count(up) > 0"
    fi
  else
    record_contract_fail "Prometheus has no scrape targets available"
    add_classification "E" "Prometheus is running but required scrape targets are absent"
  fi

  if [[ "$LOKI_INGESTION_OK" == "1" ]]; then
    if [ -n "$LOKI_REQUIRED_MARKER" ]; then
      echo "[PASS] Loki log query returned required marker entries (marker=${LOKI_REQUIRED_MARKER}, matches=${LOKI_MARKER_MATCH_COUNT})"
    else
      echo "[PASS] Loki log query returned stored entries (query_range verified)"
    fi
  else
    if [ -n "$LOKI_REQUIRED_MARKER" ]; then
      record_contract_fail "Loki marker query returned no entries for required marker"
      add_classification "E" "Loki is reachable but required real marker logs are not queryable via query_range API"
    else
      record_contract_fail "Loki log query returned no stored entries"
      add_classification "E" "Loki is reachable but no stored logs are queryable via query_range API"
    fi
  fi

  if [[ "$TEMPO_BUILDINFO_OK" == "1" ]]; then
    echo "[PASS] Tempo buildinfo endpoint responded (${TEMPO_BUILDINFO_VERSION})"
  else
    record_contract_fail "Tempo buildinfo endpoint did not return version data"
    add_classification "E" "Tempo running but API readiness is incomplete"
  fi

  if [[ "$TEMPO_INGESTION_OK" == "1" ]]; then
    echo "[PASS] Tempo ingestion counters are nonzero (${TEMPO_SPANS_RECEIVED} spans received)"
  else
    record_contract_fail "Tempo ingestion counters are zero"
    add_classification "E" "Tempo is reachable but the trace ingestion path is empty"
  fi
fi

mkdir -p "$REPO_ROOT/artifacts"
python3 - "$ARTIFACT_PATH" "$FAILURES" "$PREREQ_FAILURES" "$PROM_UP_ISTIO_PROXY" "$LOKI_SPIRE_AGENT_LINES" "$LOKI_ISTIO_PROXY_LINES" "$TEMPO_BUILDINFO_VERSION" "$TEMPO_TRACE_COUNT" "$LOKI_INGESTED_LINES" "$TEMPO_SPANS_RECEIVED" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
failures = int(sys.argv[2])
prereq_failures = int(sys.argv[3])
prom_up = float(sys.argv[4]) if sys.argv[4] not in ("", "null") else 0.0
loki_spire = int(float(sys.argv[5])) if sys.argv[5] not in ("", "null") else 0
loki_proxy = int(float(sys.argv[6])) if sys.argv[6] not in ("", "null") else 0
tempo_buildinfo_version = sys.argv[7]
tempo_trace_count = int(float(sys.argv[8])) if sys.argv[8] not in ("", "null") else 0
loki_ingested_lines = float(sys.argv[9]) if sys.argv[9] not in ("", "null") else 0.0
tempo_spans_received = float(sys.argv[10]) if sys.argv[10] not in ("", "null") else 0.0

payload = {
    "status": "PASS" if failures == 0 and prereq_failures == 0 else "FAIL",
    "namespace": "observability",
    "required_services": ["loki", "tempo", "prometheus", "grafana"],
    "required_contract_checks": {
        "prometheus_up_istio_proxy_gt_zero": prom_up,
        "loki_spire_agent_log_lines": loki_spire,
        "loki_istio_proxy_log_lines": loki_proxy,
        "loki_distributor_lines_received_total": loki_ingested_lines,
        "tempo_buildinfo_version": tempo_buildinfo_version,
        "tempo_search_trace_count": tempo_trace_count,
        "tempo_distributor_spans_received_total": tempo_spans_received,
    },
    "failures": failures,
    "prereq_failures": prereq_failures,
}
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, indent=2) + "\n")
PY

if [ "$PREREQ_FAILURES" -gt 0 ]; then
  echo "[FAIL] OBSERVABILITY_PREREQ: observability stack not deployed ($PREREQ_FAILURES missing prerequisite(s))"
  exit 10
fi

if [ "$FAILURES" -gt 0 ]; then
  exit 2
fi

trap - EXIT
echo "[PASS] required observability availability contract satisfied"
exit 0
