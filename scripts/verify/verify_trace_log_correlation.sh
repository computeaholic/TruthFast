#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=EVENT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEBUG_LOG_PATH="$REPO_ROOT/artifacts/debug/trace_correlation_failure.log"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"
# shellcheck source=scripts/lib/observability_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/observability_phase_helpers.sh"

kubectl() {
  run_real_kubectl "$@"
}

# =============================================================================
# verify_trace_log_correlation.sh — ThreadForge trace-log correlation proof
#
# Correlation contract:
#   REQUIRED: same trace_id appears in BOTH Loki logs and Tempo traces.
#
# Exit code:
#   0  = logs ↔ traces correlation proven
#   10 = tracing prerequisites missing (Loki/Tempo absent)
#   1  = correlation check failed
# =============================================================================

CORRELATION_WINDOW="${CORRELATION_WINDOW_MINUTES:-15}"
CORRELATION_READY_TIMEOUT_SECONDS="${CORRELATION_READY_TIMEOUT_SECONDS:-30}"
CORRELATION_READY_POLL_SECONDS="${CORRELATION_READY_POLL_SECONDS:-2}"
LOKI_NAMESPACE="${LOKI_NAMESPACE:-}"
TEMPO_NAMESPACE="${TEMPO_NAMESPACE:-}"
LAST_PROBE_SERVICE=""
LAST_PROBE_ENDPOINTS=""
LAST_PROBE_URL=""
LAST_PROBE_POD=""
LAST_PROBE_RESPONSE=""

first_ready_pod() {
  local ns="$1"
  local label="$2"
  kubectl get pods -n "$ns" -l "$label" -o json 2>/dev/null | python3 -c 'import json,sys
try:
  doc=json.load(sys.stdin)
except Exception:
  print("")
  raise SystemExit(0)
for item in doc.get("items", []):
  if item.get("status", {}).get("phase") != "Running":
    continue
  conds=item.get("status", {}).get("conditions", [])
  if any(c.get("type") == "Ready" and c.get("status") == "True" for c in conds):
    print(item.get("metadata", {}).get("name", ""))
    raise SystemExit(0)
print("")'
}

refresh_tempo_exec_target() {
  local candidate_pod=""
  local candidate_ns="$EXEC_NS"
  local candidate_api_url="$TEMPO_URL"
  local candidate_otlp_base_url="http://tempo.${TEMPO_NAMESPACE}.svc.cluster.local"
  local candidate_app=""

  candidate_pod="$(first_ready_pod "$TEMPO_NAMESPACE" 'app=tempo')"
  if [ -n "$candidate_pod" ]; then
    candidate_ns="$TEMPO_NAMESPACE"
    candidate_app="$(kubectl get pod -n "$candidate_ns" "$candidate_pod" -o jsonpath='{.metadata.labels.app}' 2>/dev/null || echo "")"
    if [ "$candidate_app" = "tempo" ]; then
      candidate_api_url="http://127.0.0.1:3100"
      candidate_otlp_base_url="http://127.0.0.1"
    fi
  else
    candidate_pod="$EXEC_POD"
  fi

  TEMPO_EXEC_NS="$candidate_ns"
  TEMPO_EXEC_POD="$candidate_pod"
  TEMPO_API_URL="$candidate_api_url"
  TEMPO_OTLP_BASE_URL="$candidate_otlp_base_url"
}

refresh_loki_exec_target() {
  local candidate_pod=""
  local candidate_ns="$EXEC_NS"
  local candidate_api_url="$LOKI_URL"
  local candidate_app=""

  candidate_pod="$(first_ready_pod "$LOKI_NAMESPACE" 'app=loki')"
  if [ -n "$candidate_pod" ]; then
    candidate_ns="$LOKI_NAMESPACE"
    candidate_app="$(kubectl get pod -n "$candidate_ns" "$candidate_pod" -o jsonpath='{.metadata.labels.app}' 2>/dev/null || echo "")"
    if [ "$candidate_app" = "loki" ]; then
      candidate_api_url="http://127.0.0.1:3100"
    fi
  else
    candidate_pod="$EXEC_POD"
  fi

  LOKI_EXEC_NS="$candidate_ns"
  LOKI_EXEC_POD="$candidate_pod"
  LOKI_API_URL="$candidate_api_url"
}

probe_loki_ready() {
  local loki_probe=""

  refresh_loki_exec_target
  LAST_PROBE_SERVICE="loki"
  LAST_PROBE_ENDPOINTS="$(observability_discover_endpoints "$LOKI_NAMESPACE" loki)"
  LAST_PROBE_URL="$LOKI_API_URL/loki/api/v1/labels"
  LAST_PROBE_POD="$LOKI_EXEC_NS/$LOKI_EXEC_POD"
  loki_probe="$(observability_exec_curl "$LOKI_EXEC_NS" "$LOKI_EXEC_POD" "$LAST_PROBE_URL")"
  LAST_PROBE_RESPONSE="$loki_probe"
  if printf '%s' "$loki_probe" | grep -q '"status":"success"'; then
    return 0
  fi
  return 1
}

probe_tempo_ready() {
  local tempo_probe=""

  refresh_tempo_exec_target
  LAST_PROBE_SERVICE="tempo"
  LAST_PROBE_ENDPOINTS="$(observability_discover_endpoints "$TEMPO_NAMESPACE" tempo)"
  LAST_PROBE_URL="$TEMPO_API_URL/ready"
  LAST_PROBE_POD="$TEMPO_EXEC_NS/$TEMPO_EXEC_POD"
  tempo_probe="$(observability_exec_curl "$TEMPO_EXEC_NS" "$TEMPO_EXEC_POD" "$LAST_PROBE_URL")"
  LAST_PROBE_RESPONSE="$tempo_probe"
  if printf '%s' "$tempo_probe" | grep -q 'ready'; then
    return 0
  fi
  return 1
}

write_debug_log() {
  mkdir -p "$(dirname "$DEBUG_LOG_PATH")"
  {
    echo "service=$LAST_PROBE_SERVICE"
    echo "endpoints=$LAST_PROBE_ENDPOINTS"
    echo "url=$LAST_PROBE_URL"
    echo "pod=$LAST_PROBE_POD"
    echo "raw_http_response<<'EOF'"
    printf '%s\n' "$LAST_PROBE_RESPONSE"
    echo "EOF"
  } > "$DEBUG_LOG_PATH"
}

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    write_debug_log
  fi
}
trap on_exit EXIT

echo "[correlation] Checking Loki -> Tempo trace correlation (window: ${CORRELATION_WINDOW}m)"

if [ -z "$LOKI_NAMESPACE" ]; then
  LOKI_NAMESPACE="$(observability_find_ns_by_service loki)"
fi
if [ -z "$TEMPO_NAMESPACE" ]; then
  TEMPO_NAMESPACE="$(observability_find_ns_by_service tempo)"
fi

if [ -z "$LOKI_NAMESPACE" ] || [ -z "$TEMPO_NAMESPACE" ]; then
  echo "[FAIL] Loki/Tempo services were not discovered in-cluster"
  exit 10
fi

LOKI_URL="${LOKI_URL:-$(observability_discover_svc_url "$LOKI_NAMESPACE" loki)}"
TEMPO_URL="${TEMPO_URL:-$(observability_discover_svc_url "$TEMPO_NAMESPACE" tempo)}"

if [ -z "$LOKI_URL" ]; then
  echo "[FAIL] Loki service not found in namespace: $LOKI_NAMESPACE"
  exit 10
fi
if [ -z "$TEMPO_URL" ]; then
  echo "[FAIL] Tempo service not found in namespace: $TEMPO_NAMESPACE"
  exit 10
fi

echo "[correlation] Loki URL:  $LOKI_URL"
echo "[correlation] Tempo URL: $TEMPO_URL"
echo "[correlation] Loki namespace:  $LOKI_NAMESPACE"
echo "[correlation] Tempo namespace: $TEMPO_NAMESPACE"

EXEC_NS="$LOKI_NAMESPACE"
EXEC_POD="$(observability_find_exec_pod "$EXEC_NS")"
if [ -z "$EXEC_POD" ]; then
  EXEC_NS="$TEMPO_NAMESPACE"
  EXEC_POD="$(observability_find_exec_pod "$EXEC_NS")"
fi
if [ -z "$EXEC_POD" ]; then
  echo "[FAIL] no running pod in Loki/Tempo namespace to exec into"
  exit 2
fi

echo "[correlation] exec pod: $EXEC_NS/$EXEC_POD"

refresh_tempo_exec_target
refresh_loki_exec_target

echo "[correlation] loki exec pod: $LOKI_EXEC_NS/$LOKI_EXEC_POD"
echo "[correlation] Loki API URL:  $LOKI_API_URL"
echo "[correlation] tempo exec pod: $TEMPO_EXEC_NS/$TEMPO_EXEC_POD"
echo "[correlation] Tempo API URL: $TEMPO_API_URL"

loki_ready=false
tempo_ready=false
readiness_deadline=$((SECONDS + CORRELATION_READY_TIMEOUT_SECONDS))
while true; do
  if probe_loki_ready; then
    if [ "$loki_ready" = "false" ]; then
      echo "[correlation] Loki: ready"
    fi
    loki_ready=true
  fi
  if probe_tempo_ready; then
    if [ "$tempo_ready" = "false" ]; then
      echo "[correlation] tempo exec pod: $TEMPO_EXEC_NS/$TEMPO_EXEC_POD"
      echo "[correlation] Tempo API URL: $TEMPO_API_URL"
      echo "[correlation] Tempo: ready"
    fi
    tempo_ready=true
  fi
  if [ "$loki_ready" = "true" ] && [ "$tempo_ready" = "true" ]; then
    break
  fi
  if [ "$SECONDS" -ge "$readiness_deadline" ]; then
    break
  fi
  sleep "$CORRELATION_READY_POLL_SECONDS"
done
if [ "$loki_ready" = "false" ] || [ "$tempo_ready" = "false" ]; then
  if [ "$loki_ready" = "false" ]; then
    LAST_PROBE_SERVICE="loki"
    LAST_PROBE_ENDPOINTS="$(observability_discover_endpoints "$LOKI_NAMESPACE" loki)"
    LAST_PROBE_URL="$LOKI_API_URL/loki/api/v1/labels"
    LAST_PROBE_POD="$LOKI_EXEC_NS/$LOKI_EXEC_POD"
    LAST_PROBE_RESPONSE="$(observability_exec_curl "$LOKI_EXEC_NS" "$LOKI_EXEC_POD" "$LAST_PROBE_URL")"
    echo "[FAIL] Loki API not reachable at $LOKI_API_URL"
  fi
  if [ "$tempo_ready" = "false" ]; then
    LAST_PROBE_SERVICE="tempo"
    LAST_PROBE_ENDPOINTS="$(observability_discover_endpoints "$TEMPO_NAMESPACE" tempo)"
    LAST_PROBE_URL="$TEMPO_API_URL/ready"
    LAST_PROBE_POD="$TEMPO_EXEC_NS/$TEMPO_EXEC_POD"
    LAST_PROBE_RESPONSE="$(observability_exec_curl "$TEMPO_EXEC_NS" "$TEMPO_EXEC_POD" "$LAST_PROBE_URL")"
    echo "[FAIL] Tempo not ready at $TEMPO_API_URL"
  fi
  echo "[FAIL] correlation proof requires both Loki and Tempo to be ready"
  exit 2
fi

NOW_NANO=$(date +%s)000000000
START_NANO=$(( ($(date +%s) - CORRELATION_WINDOW * 60) ))000000000

TEMPO_OTLP_PORT=$(kubectl get svc -n "$TEMPO_NAMESPACE" tempo -o jsonpath='{.spec.ports[?(@.port==4318)].port}' 2>/dev/null || echo "")
if [ -z "$TEMPO_OTLP_PORT" ]; then
  TEMPO_OTLP_PORT="4318"
fi
TEMPO_OTLP_URL="${TEMPO_OTLP_BASE_URL}:${TEMPO_OTLP_PORT}"

TRACE_ID="$(python3 - <<'PY'
import random
print(f"{random.getrandbits(128):032x}")
PY
)"
SPAN_ID="$(python3 - <<'PY'
import random
print(f"{random.getrandbits(64):016x}")
PY
)"
TS_NANO="$(date +%s)000000000"

echo "[correlation] Injecting correlated signal trace_id=$TRACE_ID"

LOKI_PUSH_PAYLOAD=$(cat <<JSON
{"streams":[{"stream":{"job":"trace-log-correlation"},"values":[["${TS_NANO}","trace_id=${TRACE_ID} correlation_check=true"]]}]}
JSON
)

kubectl exec -n "$LOKI_EXEC_NS" "$LOKI_EXEC_POD" -c istio-proxy -- \
  curl --silent --max-time 10 -H 'Content-Type: application/json' \
  -X POST "${LOKI_API_URL}/loki/api/v1/push" \
  --data "$LOKI_PUSH_PAYLOAD" >/dev/null 2>/dev/null \
  || kubectl exec -n "$LOKI_EXEC_NS" "$LOKI_EXEC_POD" -- \
    curl --silent --max-time 10 -H 'Content-Type: application/json' \
    -X POST "${LOKI_API_URL}/loki/api/v1/push" \
    --data "$LOKI_PUSH_PAYLOAD" >/dev/null

TEMPO_PUSH_PAYLOAD=$(cat <<JSON
{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"trace-log-correlation"}}]},"scopeSpans":[{"spans":[{"traceId":"${TRACE_ID}","spanId":"${SPAN_ID}","name":"correlation-check","kind":1,"startTimeUnixNano":"${TS_NANO}","endTimeUnixNano":"$((TS_NANO + 100000000))"}]}]}]}
JSON
)

kubectl exec -n "$TEMPO_EXEC_NS" "$TEMPO_EXEC_POD" -c istio-proxy -- \
  curl --silent --max-time 10 -H 'Content-Type: application/json' \
  -X POST "${TEMPO_OTLP_URL}/v1/traces" \
  --data "$TEMPO_PUSH_PAYLOAD" >/dev/null 2>/dev/null \
  || kubectl exec -n "$TEMPO_EXEC_NS" "$TEMPO_EXEC_POD" -- \
    curl --silent --max-time 10 -H 'Content-Type: application/json' \
    -X POST "${TEMPO_OTLP_URL}/v1/traces" \
    --data "$TEMPO_PUSH_PAYLOAD" >/dev/null

sleep 4
NOW_NANO=$(date +%s)000000000
START_NANO=$(( ($(date +%s) - CORRELATION_WINDOW * 60) ))000000000

echo "[correlation] Querying Loki for injected trace_id..."
LAST_PROBE_SERVICE="loki-query"
LAST_PROBE_ENDPOINTS="$(observability_discover_endpoints "$LOKI_NAMESPACE" loki)"
LAST_PROBE_POD="$LOKI_EXEC_NS/$LOKI_EXEC_POD"
LOKI_RESPONSE=$(kubectl exec -n "$LOKI_EXEC_NS" "$LOKI_EXEC_POD" -c istio-proxy -- \
  curl --silent --max-time 15 \
  "${LOKI_API_URL}/loki/api/v1/query_range" \
  --data-urlencode "query={job=\"trace-log-correlation\"} |= \"${TRACE_ID}\"" \
  --data-urlencode "start=${START_NANO}" \
  --data-urlencode "end=${NOW_NANO}" \
  --data-urlencode "limit=20" 2>/dev/null \
  || kubectl exec -n "$LOKI_EXEC_NS" "$LOKI_EXEC_POD" -- \
    curl --silent --max-time 15 \
    "${LOKI_API_URL}/loki/api/v1/query_range" \
    --data-urlencode "query={job=\"trace-log-correlation\"} |= \"${TRACE_ID}\"" \
    --data-urlencode "start=${START_NANO}" \
    --data-urlencode "end=${NOW_NANO}" \
    --data-urlencode "limit=20" 2>/dev/null \
  || echo "")
LAST_PROBE_RESPONSE="$LOKI_RESPONSE"

if ! echo "$LOKI_RESPONSE" | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("data",{}).get("result",[]); raise SystemExit(0 if r and any(s.get("values") for s in r) else 1)' 2>/dev/null; then
  echo "[FAIL] injected trace_id was not found in Loki"
  exit 2
fi

echo "[correlation] Looking up injected trace_id in Tempo..."
LAST_PROBE_SERVICE="tempo-trace"
LAST_PROBE_ENDPOINTS="$(observability_discover_endpoints "$TEMPO_NAMESPACE" tempo)"
LAST_PROBE_POD="$TEMPO_EXEC_NS/$TEMPO_EXEC_POD"
TEMPO_RESPONSE=$(kubectl exec -n "$TEMPO_EXEC_NS" "$TEMPO_EXEC_POD" -c istio-proxy -- \
  curl --silent --max-time 15 \
  "${TEMPO_API_URL}/api/traces/${TRACE_ID}" 2>/dev/null \
  || kubectl exec -n "$TEMPO_EXEC_NS" "$TEMPO_EXEC_POD" -- \
    curl --silent --max-time 15 \
    "${TEMPO_API_URL}/api/traces/${TRACE_ID}" 2>/dev/null \
  || echo "")
LAST_PROBE_RESPONSE="$TEMPO_RESPONSE"

if ! echo "$TEMPO_RESPONSE" | python3 -c '
import json, sys
p = json.load(sys.stdin)
spans = 0
for rs in p.get("resourceSpans", p.get("batches", [])):
    for ss in rs.get("scopeSpans", rs.get("instrumentationLibrarySpans", [])):
        spans += len(ss.get("spans", []))
raise SystemExit(0 if spans > 0 else 1)
' 2>/dev/null; then
  echo "[FAIL] injected trace_id was not found in Tempo"
  exit 2
fi

echo "[PASS] trace_id $TRACE_ID confirmed in both Loki logs and Tempo traces"
echo "[PASS] trace-log correlation contract satisfied"
exit 0
