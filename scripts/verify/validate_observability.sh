#!/usr/bin/env bash
set -euo pipefail

export OBSERVE_TYPE=CORRELATION

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_PATH="$REPO_ROOT/artifacts/observability_validation.json"
DEBUG_LOG_PATH="$REPO_ROOT/artifacts/debug/observe_failure.log"
SUMMARY_PATH="$REPO_ROOT/artifacts/debug/observe_summary.json"
# shellcheck source=scripts/lib/identity_contract.sh
source "$REPO_ROOT/scripts/lib/identity_contract.sh"
require_trust_domain
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"
# shellcheck source=scripts/lib/observability_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/observability_phase_helpers.sh"

kubectl() {
  run_real_kubectl "$@"
}

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

CHECKS_RUN=0
CHECKS_PASSED=0
CHECKS_FAILED=0
EVIDENCE_COMPLETE=true
FAILURES=()
SIGNALS_EMITTED=false
SIGNALS_INGESTED=false
SIGNALS_QUERYABLE=false
CORRELATION_PROVEN=false

PROM_NAMESPACE=""
LOKI_NAMESPACE=""
TEMPO_NAMESPACE=""
PROM_URL=""
LOKI_URL=""
TEMPO_URL=""
TEMPO_OTLP_URL=""
EXEC_NS=""
EXEC_POD=""
TEMPO_EXEC_NS=""
TEMPO_EXEC_POD=""
TEMPO_API_URL=""
TRACE_ID=""
SPAN_ID=""
TS_NANO=""

PROM_READY_RESPONSE=""
PROM_QUERY_RESPONSE=""
LOKI_READY_RESPONSE=""
LOKI_PUSH_RESPONSE=""
LOKI_QUERY_RESPONSE=""
TEMPO_READY_RESPONSE=""
TEMPO_PUSH_RESPONSE=""
TEMPO_QUERY_RESPONSE=""
PROM_ENDPOINTS=""
LOKI_ENDPOINTS=""
TEMPO_ENDPOINTS=""

record_start() {
  local check_name="$1"
  CHECKS_RUN=$((CHECKS_RUN + 1))
  echo "[observe] START check=${check_name}"
}

record_pass() {
  local check_name="$1"
  local message="$2"
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
  echo "[observe] PASS check=${check_name} ${message}"
}

record_fail() {
  local check_name="$1"
  local message="$2"
  CHECKS_FAILED=$((CHECKS_FAILED + 1))
  FAILURES+=("${check_name}: ${message}")
  echo "[FAIL] observe ${check_name}: ${message}"
}

write_summary() {
  mkdir -p "$(dirname "$SUMMARY_PATH")"
  python3 - "$SUMMARY_PATH" "$CHECKS_RUN" "$CHECKS_PASSED" "$CHECKS_FAILED" "$EVIDENCE_COMPLETE" <<'PY'
import json
import pathlib
import sys

summary_path = pathlib.Path(sys.argv[1])
payload = {
    "checks_run": int(sys.argv[2]),
    "checks_passed": int(sys.argv[3]),
    "checks_failed": int(sys.argv[4]),
    "evidence_complete": sys.argv[5].lower() == "true",
}
summary_path.write_text(json.dumps(payload, indent=2) + "\n")
PY
}

write_result_artifact() {
  mkdir -p "$REPO_ROOT/artifacts"
  python3 - "$ARTIFACT_PATH" "$TRACE_ID" "$PROM_NAMESPACE" "$LOKI_NAMESPACE" "$TEMPO_NAMESPACE" "$SIGNALS_EMITTED" "$SIGNALS_INGESTED" "$SIGNALS_QUERYABLE" "$CORRELATION_PROVEN" "$CHECKS_FAILED" <<'PY'
import json
import pathlib
import sys

artifact_path = pathlib.Path(sys.argv[1])
payload = {
    "status": "pass" if int(sys.argv[10]) == 0 else "fail",
    "trace_id": sys.argv[2],
    "prometheus_namespace": sys.argv[3],
    "loki_namespace": sys.argv[4],
    "tempo_namespace": sys.argv[5],
    "contract": {
        "signals_emitted": sys.argv[6].lower() == "true",
        "signals_ingested": sys.argv[7].lower() == "true",
        "signals_queryable": sys.argv[8].lower() == "true",
        "cross_system_correlation": sys.argv[9].lower() == "true",
    },
}
artifact_path.write_text(json.dumps(payload, indent=2) + "\n")
PY
}

write_failure_debug_log() {
  mkdir -p "$(dirname "$DEBUG_LOG_PATH")"
  {
    echo "## 1. Observability pods"
    echo "command: kubectl -n observability get pods -o wide"
    kubectl -n observability get pods -o wide 2>&1 || true
    echo
    echo "## 2. Services + endpoints"
    echo "command: kubectl -n observability get svc"
    kubectl -n observability get svc 2>&1 || true
    echo
    echo "command: kubectl -n observability get endpoints"
    kubectl -n observability get endpoints 2>&1 || true
    echo
    echo "## 3. Logs"
    echo "command: kubectl -n observability logs deploy/prometheus --tail=100"
    kubectl -n observability logs deploy/prometheus --tail=100 2>&1 || true
    echo
    echo "command: kubectl -n observability logs deploy/loki --tail=100"
    kubectl -n observability logs deploy/loki --tail=100 2>&1 || true
    echo
    echo "command: kubectl -n observability logs deploy/tempo --tail=100"
    kubectl -n observability logs deploy/tempo --tail=100 2>&1 || true
    echo
    echo "## 4. Query attempts + raw responses"
    echo "exec_pod=${EXEC_NS}/${EXEC_POD}"
    echo "prometheus_endpoints=${PROM_ENDPOINTS}"
    echo "loki_endpoints=${LOKI_ENDPOINTS}"
    echo "tempo_endpoints=${TEMPO_ENDPOINTS}"
    echo "prometheus_ready_url=${PROM_URL}/-/ready"
    echo "prometheus_query_url=${PROM_URL}/api/v1/query?query=count(up)%20%3E%200"
    echo "loki_ready_url=${LOKI_URL}/loki/api/v1/labels"
    echo "loki_push_url=${LOKI_URL}/loki/api/v1/push"
    echo "loki_query_url=${LOKI_URL}/loki/api/v1/query_range?query={job=\"threadforge-observe\"}%20|=%20\"${TRACE_ID}\""
    echo "tempo_ready_url=${TEMPO_API_URL}/ready"
    echo "tempo_push_url=${TEMPO_OTLP_URL}/v1/traces"
    echo "tempo_query_url=${TEMPO_API_URL}/api/traces/${TRACE_ID}"
    echo
    echo "failures<<'EOF'"
    if [ "${#FAILURES[@]}" -gt 0 ]; then
      printf '%s\n' "${FAILURES[@]}"
    fi
    echo "EOF"
    echo
    echo "prometheus_ready_response<<'EOF'"
    printf '%s\n' "$PROM_READY_RESPONSE"
    echo "EOF"
    echo "prometheus_query_response<<'EOF'"
    printf '%s\n' "$PROM_QUERY_RESPONSE"
    echo "EOF"
    echo "loki_ready_response<<'EOF'"
    printf '%s\n' "$LOKI_READY_RESPONSE"
    echo "EOF"
    echo "loki_push_response<<'EOF'"
    printf '%s\n' "$LOKI_PUSH_RESPONSE"
    echo "EOF"
    echo "loki_query_response<<'EOF'"
    printf '%s\n' "$LOKI_QUERY_RESPONSE"
    echo "EOF"
    echo "tempo_ready_response<<'EOF'"
    printf '%s\n' "$TEMPO_READY_RESPONSE"
    echo "EOF"
    echo "tempo_push_response<<'EOF'"
    printf '%s\n' "$TEMPO_PUSH_RESPONSE"
    echo "EOF"
    echo "tempo_query_response<<'EOF'"
    printf '%s\n' "$TEMPO_QUERY_RESPONSE"
    echo "EOF"
  } > "$DEBUG_LOG_PATH"
}

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    write_failure_debug_log
    if [ ! -s "$DEBUG_LOG_PATH" ]; then
      EVIDENCE_COMPLETE=false
    fi
  fi
  write_result_artifact
  write_summary
}
trap on_exit EXIT

post_json_via_exec_pod() {
  local exec_ns="$1"
  local exec_pod="$2"
  local url="$3"
  local payload_json="$4"
  local payload_b64=""
  payload_b64="$(printf '%s' "$payload_json" | base64 | tr -d '\n')"
  kubectl exec -n "$exec_ns" "$exec_pod" -c istio-proxy -- sh -lc "printf '%s' '$payload_b64' | base64 -d | curl -i --silent --show-error --max-time 15 -H 'Content-Type: application/json' --data-binary @- '$url'" 2>/dev/null \
    || kubectl exec -n "$exec_ns" "$exec_pod" -- sh -lc "printf '%s' '$payload_b64' | base64 -d | curl -i --silent --show-error --max-time 15 -H 'Content-Type: application/json' --data-binary @- '$url'" 2>/dev/null \
    || true
}

await_loki_signal() {
  local deadline="$(($(date +%s) + 20))"
  local attempt=1

  while [ "$(date +%s)" -le "$deadline" ]; do
    echo "[observe] ATTEMPT check=signal_query_loki attempt=${attempt}"
    LOKI_QUERY_RESPONSE="$(kubectl exec -n "$EXEC_NS" "$EXEC_POD" -c istio-proxy -- \
      curl --silent --show-error --max-time 15 \
      "${LOKI_URL}/loki/api/v1/query_range" \
      --data-urlencode "query={job=\"threadforge-observe\"} |= \"${TRACE_ID}\"" \
      --data-urlencode "start=${START_NANO}" \
      --data-urlencode "end=${NOW_NANO}" \
      --data-urlencode "limit=20" 2>/dev/null \
      || kubectl exec -n "$EXEC_NS" "$EXEC_POD" -- \
        curl --silent --show-error --max-time 15 \
        "${LOKI_URL}/loki/api/v1/query_range" \
        --data-urlencode "query={job=\"threadforge-observe\"} |= \"${TRACE_ID}\"" \
        --data-urlencode "start=${START_NANO}" \
        --data-urlencode "end=${NOW_NANO}" \
        --data-urlencode "limit=20" 2>/dev/null \
      || true)"
    if printf '%s' "$LOKI_QUERY_RESPONSE" | python3 -c 'import json,sys; doc=json.load(sys.stdin); result=doc.get("data",{}).get("result",[]); raise SystemExit(0 if result and any(s.get("values") for s in result) else 1)' 2>/dev/null; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
    NOW_NANO="$(date +%s)000000000"
  done

  return 1
}

await_tempo_trace() {
  local deadline="$(($(date +%s) + 20))"
  local attempt=1

  while [ "$(date +%s)" -le "$deadline" ]; do
    echo "[observe] ATTEMPT check=signal_query_tempo attempt=${attempt}"
    TEMPO_QUERY_RESPONSE="$(observability_exec_curl "$TEMPO_EXEC_NS" "$TEMPO_EXEC_POD" "${TEMPO_API_URL}/api/traces/${TRACE_ID}" "--silent --show-error --max-time 15")"
    if printf '%s' "$TEMPO_QUERY_RESPONSE" | python3 -c 'import json,sys; doc=json.load(sys.stdin); spans=0
for rs in doc.get("resourceSpans", doc.get("batches", [])):
  for ss in rs.get("scopeSpans", rs.get("instrumentationLibrarySpans", [])):
    spans += len(ss.get("spans", []))
raise SystemExit(0 if spans > 0 else 1)' 2>/dev/null; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done

  return 1
}

ensure_cluster_readable || exit $?

echo "[observe] START validate_observability"

PROM_NAMESPACE="${PROM_NAMESPACE:-$(observability_find_ns_by_service prometheus)}"
LOKI_NAMESPACE="${LOKI_NAMESPACE:-$(observability_find_ns_by_service loki)}"
TEMPO_NAMESPACE="${TEMPO_NAMESPACE:-$(observability_find_ns_by_service tempo)}"

if [ -z "$PROM_NAMESPACE" ] || [ -z "$LOKI_NAMESPACE" ] || [ -z "$TEMPO_NAMESPACE" ]; then
  record_fail "resolve_stack" "required observability services were not discovered"
  exit 10
fi

PROM_URL="$(observability_discover_svc_url "$PROM_NAMESPACE" prometheus)"
LOKI_URL="$(observability_discover_svc_url "$LOKI_NAMESPACE" loki)"
TEMPO_URL="$(observability_discover_svc_url "$TEMPO_NAMESPACE" tempo)"
PROM_ENDPOINTS="$(observability_discover_endpoints "$PROM_NAMESPACE" prometheus)"
LOKI_ENDPOINTS="$(observability_discover_endpoints "$LOKI_NAMESPACE" loki)"
TEMPO_ENDPOINTS="$(observability_discover_endpoints "$TEMPO_NAMESPACE" tempo)"

if [ -z "$PROM_URL" ] || [ -z "$LOKI_URL" ] || [ -z "$TEMPO_URL" ]; then
  record_fail "resolve_stack" "one or more observability service URLs could not be constructed"
  exit 10
fi

EXEC_NS="$LOKI_NAMESPACE"
EXEC_POD="$(observability_find_exec_pod "$EXEC_NS")"
if [ -z "$EXEC_POD" ]; then
  EXEC_NS="$TEMPO_NAMESPACE"
  EXEC_POD="$(observability_find_exec_pod "$EXEC_NS")"
fi
if [ -z "$EXEC_POD" ]; then
  record_fail "resolve_exec_pod" "no running pod available for in-cluster observation queries"
  exit 2
fi

TEMPO_EXEC_NS="$TEMPO_NAMESPACE"
TEMPO_EXEC_POD="$(first_ready_pod "$TEMPO_NAMESPACE" 'app=tempo')"
if [ -z "$TEMPO_EXEC_POD" ]; then
  TEMPO_EXEC_NS="$EXEC_NS"
  TEMPO_EXEC_POD="$EXEC_POD"
fi

TEMPO_API_URL="$TEMPO_URL"
if [ "$TEMPO_EXEC_NS" = "$TEMPO_NAMESPACE" ]; then
  tempo_exec_app="$(kubectl get pod -n "$TEMPO_EXEC_NS" "$TEMPO_EXEC_POD" -o jsonpath='{.metadata.labels.app}' 2>/dev/null || echo "")"
  if [ "$tempo_exec_app" = "tempo" ]; then
    TEMPO_API_URL="http://127.0.0.1:3100"
  fi
fi

TEMPO_OTLP_PORT="$(kubectl get svc -n "$TEMPO_NAMESPACE" tempo -o jsonpath='{.spec.ports[?(@.port==4318)].port}' 2>/dev/null || true)"
if [ -z "$TEMPO_OTLP_PORT" ]; then
  TEMPO_OTLP_PORT="4318"
fi
if [ "$TEMPO_API_URL" = "http://127.0.0.1:3100" ]; then
  TEMPO_OTLP_URL="http://127.0.0.1:${TEMPO_OTLP_PORT}"
else
  TEMPO_OTLP_URL="http://tempo.${TEMPO_NAMESPACE}.svc.cluster.local:${TEMPO_OTLP_PORT}"
fi

echo "[observe] using exec pod ${EXEC_NS}/${EXEC_POD}"
echo "[observe] using tempo exec pod ${TEMPO_EXEC_NS}/${TEMPO_EXEC_POD}"
echo "[observe] Prometheus URL: ${PROM_URL}"
echo "[observe] Loki URL: ${LOKI_URL}"
echo "[observe] Tempo URL: ${TEMPO_API_URL}"

record_start "stack_liveness"
PROM_READY_RESPONSE="$(observability_exec_curl "$EXEC_NS" "$EXEC_POD" "${PROM_URL}/-/ready" "--silent --show-error --max-time 10")"
PROM_QUERY_RESPONSE="$(observability_exec_curl "$EXEC_NS" "$EXEC_POD" "${PROM_URL}/api/v1/query?query=count%28up%29%20%3E%200" "--silent --show-error --max-time 10")"
LOKI_READY_RESPONSE="$(observability_exec_curl "$EXEC_NS" "$EXEC_POD" "${LOKI_URL}/loki/api/v1/labels" "--silent --show-error --max-time 10")"
TEMPO_READY_RESPONSE="$(observability_exec_curl "$TEMPO_EXEC_NS" "$TEMPO_EXEC_POD" "${TEMPO_API_URL}/ready" "--silent --show-error --max-time 10")"
if printf '%s' "$PROM_QUERY_RESPONSE" | python3 -c 'import json,sys; doc=json.load(sys.stdin); result=doc.get("data",{}).get("result",[]); raise SystemExit(0 if result else 1)' 2>/dev/null \
  && printf '%s' "$LOKI_READY_RESPONSE" | grep -q '"status":"success"' \
  && printf '%s' "$TEMPO_READY_RESPONSE" | grep -q 'ready'; then
  record_pass "stack_liveness" "prometheus, loki, and tempo are reachable through proof query paths"
else
  record_fail "stack_liveness" "one or more observability query paths failed readiness validation"
  exit 2
fi

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

LOKI_PUSH_PAYLOAD=$(cat <<JSON
{"streams":[{"stream":{"job":"threadforge-observe"},"values":[["${TS_NANO}","trace_id=${TRACE_ID} observe_phase=true"]]}]}
JSON
)
TEMPO_PUSH_PAYLOAD=$(cat <<JSON
{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"threadforge-observe"}}]},"scopeSpans":[{"spans":[{"traceId":"${TRACE_ID}","spanId":"${SPAN_ID}","name":"observe-correlation","kind":1,"startTimeUnixNano":"${TS_NANO}","endTimeUnixNano":"$((TS_NANO + 100000000))"}]}]}]}
JSON
)

record_start "signal_emission"
LOKI_PUSH_RESPONSE="$(post_json_via_exec_pod "$EXEC_NS" "$EXEC_POD" "${LOKI_URL}/loki/api/v1/push" "$LOKI_PUSH_PAYLOAD")"
TEMPO_PUSH_RESPONSE="$(post_json_via_exec_pod "$TEMPO_EXEC_NS" "$TEMPO_EXEC_POD" "${TEMPO_OTLP_URL}/v1/traces" "$TEMPO_PUSH_PAYLOAD")"
if printf '%s' "$LOKI_PUSH_RESPONSE" | grep -Eq 'HTTP/[0-9.]+ 20[04]' \
  && printf '%s' "$TEMPO_PUSH_RESPONSE" | grep -Eq 'HTTP/[0-9.]+ 20[04]'; then
  SIGNALS_EMITTED=true
  record_pass "signal_emission" "synthetic log and trace signals were accepted by Loki and Tempo"
else
  record_fail "signal_emission" "one or more observability ingestion endpoints rejected the emitted signal"
  exit 2
fi

NOW_NANO="$(date +%s)000000000"
START_NANO="$(( ($(date +%s) - 900) ))000000000"

record_start "signal_query_loki"
if await_loki_signal; then
  record_pass "signal_query_loki" "synthetic signal is queryable from Loki"
else
  record_fail "signal_query_loki" "synthetic signal was not queryable from Loki"
  exit 2
fi

record_start "signal_query_tempo"
if await_tempo_trace; then
  SIGNALS_INGESTED=true
  SIGNALS_QUERYABLE=true
  record_pass "signal_query_tempo" "synthetic trace is queryable from Tempo"
else
  record_fail "signal_query_tempo" "synthetic trace was not queryable from Tempo"
  exit 2
fi

record_start "cross_system_correlation"
if printf '%s' "$LOKI_QUERY_RESPONSE" | grep -q "$TRACE_ID" \
  && printf '%s' "$TEMPO_QUERY_RESPONSE" | python3 -c 'import base64, json, sys
expected = sys.argv[1]
doc = json.load(sys.stdin)
observed = set()
for rs in doc.get("resourceSpans", doc.get("batches", [])):
  for ss in rs.get("scopeSpans", rs.get("instrumentationLibrarySpans", [])):
    for span in ss.get("spans", []):
      trace_id = span.get("traceId", "")
      if not isinstance(trace_id, str) or not trace_id:
        continue
      observed.add(trace_id)
      try:
        observed.add(base64.b64decode(trace_id).hex())
      except Exception:
        pass
raise SystemExit(0 if expected in observed else 1)' "$TRACE_ID" 2>/dev/null; then
  CORRELATION_PROVEN=true
  record_pass "cross_system_correlation" "trace_id ${TRACE_ID} is visible across Loki and Tempo"
else
  record_fail "cross_system_correlation" "trace_id ${TRACE_ID} was not correlated across observability backends"
  exit 2
fi

echo "[observe] END validate_observability status=PASS trace_id=${TRACE_ID}"
