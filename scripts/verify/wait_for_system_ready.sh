#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TIMEOUT_SECONDS="${SYSTEM_READY_TIMEOUT_SECONDS:-600}"
INTERVAL_SECONDS="${SYSTEM_READY_INTERVAL_SECONDS:-5}"
THREADFORGE_NS="${THREADFORGE_READY_NAMESPACE:-threadforge-test}"

deadline="$(( $(date +%s) + TIMEOUT_SECONDS ))"

bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh"

fail() {
  echo "[FAIL] CONTRACT_VIOLATION: $1"
  exit 2
}

retry_until() {
  local description="$1"
  shift
  local output=""

  while [ "$(date +%s)" -lt "$deadline" ]; do
    if output="$($@ 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    fi
    sleep "$INTERVAL_SECONDS"
  done

  printf '%s\n' "$output"
  fail "$description"
}

wait_rollout() {
  local kind="$1"
  local namespace="$2"
  local name="$3"
  retry_until "$kind/$name in namespace $namespace did not become ready" \
    kubectl wait --for=condition=Available "$kind/$name" -n "$namespace" --timeout="${INTERVAL_SECONDS}s"
}

wait_pods_ready() {
  local namespace="$1"
  local selector="$2"
  retry_until "pods matching $selector in namespace $namespace did not become Ready" \
    kubectl wait -n "$namespace" --for=condition=Ready pod -l "$selector" --timeout="${INTERVAL_SECONDS}s"
}

service_endpoints_ready() {
  local addresses

  kubectl get svc echo -n "$THREADFORGE_NS" >/dev/null 2>&1 || return 1
  addresses="$(kubectl get endpoints echo -n "$THREADFORGE_NS" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  if [ -z "$addresses" ]; then
    return 1
  fi

  echo "[ready] echo service endpoints: $addresses"
  return 0
}

service_ports_ready() {
  local ports

  ports="$(kubectl get svc echo -n "$THREADFORGE_NS" -o jsonpath='{.spec.ports[*].port}' 2>/dev/null || true)"
  if [ -z "$ports" ]; then
    return 1
  fi

  echo "[ready] echo service ports: $ports"
  return 0
}

echo "[ready] waiting for proof workloads and DNS"

wait_pods_ready "$THREADFORGE_NS" app=echo
wait_pods_ready "$THREADFORGE_NS" app=test-client

retry_until "echo service endpoints are not yet published" service_endpoints_ready
retry_until "echo service ports are not yet published" service_ports_ready

echo "[PASS] system readiness gate satisfied: pods ready, service endpoints published"
