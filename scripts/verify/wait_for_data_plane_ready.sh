#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=LIVENESS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEBUG_LOG_PATH="$REPO_ROOT/artifacts/debug/data_plane_failure.log"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

kubectl() {
  run_real_kubectl "$@"
}

TEST_NAMESPACE="${DATA_PLANE_NAMESPACE:-threadforge-test}"
TEST_LABEL="${DATA_PLANE_TEST_LABEL:-app=test-client}"
ECHO_LABEL="${DATA_PLANE_ECHO_LABEL:-app=echo}"
TARGET_URL="${DATA_PLANE_TARGET_URL:-http://echo.threadforge-test.svc.cluster.local/healthz}"
TIMEOUT_SECONDS="${DATA_PLANE_TIMEOUT_SECONDS:-60}"
POLL_SECONDS="${DATA_PLANE_POLL_SECONDS:-2}"
LAST_REASON=""

fail() {
  LAST_REASON="$1"
  echo "[FAIL] DATA_PLANE_NOT_READY: $1"
  exit 2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 not found"
}

pod_for_label() {
  local ns="$1"
  local label="$2"
  timeout --foreground 5s kubectl get pod -n "$ns" -l "$label" --request-timeout=5s -o json 2>/dev/null | python3 -c 'import json,sys
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
  status=item.get("status") or {}
  if status.get("phase") != "Running":
    continue
  ready=any(c.get("type") == "Ready" and c.get("status") == "True" for c in (status.get("conditions") or []) if isinstance(c, dict))
  items.append((0 if ready else 1, metadata.get("creationTimestamp") or "", metadata.get("name") or ""))

items.sort()
print(items[0][2] if items else "")'
}

envoy_ready_code() {
  local ns="$1"
  local pod="$2"
  timeout --foreground 10s kubectl exec -n "$ns" "$pod" -c istio-proxy -- curl -sS --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:15021/healthz/ready 2>/dev/null || echo 000
}

traffic_code() {
  local ns="$1"
  local pod="$2"
  timeout --foreground 10s kubectl exec -n "$ns" "$pod" -c test-client -- curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$TARGET_URL" 2>/dev/null || echo 000
}

echo_service_endpoints() {
  timeout --foreground 5s kubectl get endpoints -n "$TEST_NAMESPACE" echo --request-timeout=5s -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null || true
}

write_debug_log() {
  local test_pod=""
  local echo_pod=""
  mkdir -p "$(dirname "$DEBUG_LOG_PATH")"
  test_pod="$(pod_for_label "$TEST_NAMESPACE" "$TEST_LABEL")"
  echo_pod="$(pod_for_label "$TEST_NAMESPACE" "$ECHO_LABEL")"
  {
    echo "reason=$LAST_REASON"
    echo "pods<<'EOF'"
    kubectl get pods -A -o wide 2>&1 || true
    echo "EOF"
    echo "envoy_readiness_test_client<<'EOF'"
    if [ -n "$test_pod" ]; then
      kubectl exec -n "$TEST_NAMESPACE" "$test_pod" -c istio-proxy -- curl -sS -i http://127.0.0.1:15021/healthz/ready 2>&1 || true
    else
      echo "test-client pod not found"
    fi
    echo "EOF"
    echo "envoy_readiness_echo<<'EOF'"
    if [ -n "$echo_pod" ]; then
      kubectl exec -n "$TEST_NAMESPACE" "$echo_pod" -c istio-proxy -- curl -sS -i http://127.0.0.1:15021/healthz/ready 2>&1 || true
    else
      echo "echo pod not found"
    fi
    echo "EOF"
    echo "istiod_endpoints<<'EOF'"
    kubectl get endpoints -n istio-system istiod 2>&1 || true
    echo "EOF"
    echo "proxy_status<<'EOF'"
    istioctl proxy-status 2>&1 || true
    echo "EOF"
    echo "recent_events<<'EOF'"
    kubectl get events -A --sort-by=.lastTimestamp 2>&1 | tail -n 100 || true
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

require_cmd kubectl
require_cmd istioctl

ensure_cluster_readable || exit $?

deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  test_pod="$(pod_for_label "$TEST_NAMESPACE" "$TEST_LABEL")"
  echo_pod="$(pod_for_label "$TEST_NAMESPACE" "$ECHO_LABEL")"

  if [ -z "$test_pod" ] || [ -z "$echo_pod" ]; then
    LAST_REASON="C: required data-plane pods are not running"
    sleep "$POLL_SECONDS"
    continue
  fi

  if [ -z "$(echo_service_endpoints)" ]; then
    LAST_REASON="C: service endpoints missing for echo.${TEST_NAMESPACE}.svc.cluster.local"
    sleep "$POLL_SECONDS"
    continue
  fi

  test_ready_code="$(envoy_ready_code "$TEST_NAMESPACE" "$test_pod")"
  if [ "$test_ready_code" != "200" ]; then
    LAST_REASON="B: Envoy not ready for ${TEST_NAMESPACE}/${test_pod} (readiness=${test_ready_code})"
    sleep "$POLL_SECONDS"
    continue
  fi

  echo_ready_code="$(envoy_ready_code "$TEST_NAMESPACE" "$echo_pod")"
  if [ "$echo_ready_code" != "200" ]; then
    LAST_REASON="B: Envoy not ready for ${TEST_NAMESPACE}/${echo_pod} (readiness=${echo_ready_code})"
    sleep "$POLL_SECONDS"
    continue
  fi

  traffic_probe_code="$(traffic_code "$TEST_NAMESPACE" "$test_pod")"
  if [ "$traffic_probe_code" != "200" ]; then
    LAST_REASON="D: validator probing corrected live traffic path, but in-mesh traffic still returned ${traffic_probe_code}"
    sleep "$POLL_SECONDS"
    continue
  fi

  echo "[PASS] data plane readiness validated via live Envoy readiness, service endpoints, and in-mesh traffic"
  exit 0
done

fail "${LAST_REASON:-VERIFY_TIMEOUT}"
