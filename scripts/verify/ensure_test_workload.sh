#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail_workload() {
  local message="$1"
  echo "[FAIL] BOOTSTRAP_STEP_FAILED: ${message}"
  exit 2
}

kubectl get namespace threadforge-test >/dev/null 2>&1 || fail_workload "threadforge-test namespace missing"
inject_label="$(kubectl get namespace threadforge-test -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null || true)"
[[ "$inject_label" == "enabled" ]] || fail_workload "threadforge-test namespace missing istio-injection=enabled"

kubectl get deploy/echo -n threadforge-test >/dev/null 2>&1 || fail_workload "threadforge-test/echo deployment missing"
kubectl get deploy/test-client -n threadforge-test >/dev/null 2>&1 || fail_workload "threadforge-test/test-client deployment missing"

kubectl rollout status deployment/echo -n threadforge-test --timeout=180s >/dev/null || fail_workload "threadforge-test/echo"
kubectl rollout status deployment/test-client -n threadforge-test --timeout=180s >/dev/null || fail_workload "threadforge-test/test-client"

TEST_CLIENT_POD="$(kubectl get pods -n threadforge-test -l app=test-client --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
ECHO_POD="$(kubectl get pods -n threadforge-test -l app=echo --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$TEST_CLIENT_POD" && -n "$ECHO_POD" ]] || fail_workload "threadforge-test workloads not running"

kubectl get svc echo -n threadforge-test >/dev/null 2>&1 || fail_workload "threadforge-test/echo service missing"

kubectl get pod -n threadforge-test "$TEST_CLIENT_POD" -o jsonpath='{.spec.containers[*].name}' | grep -qw istio-proxy || fail_workload "threadforge-test/test-client missing sidecar"
kubectl get pod -n threadforge-test "$ECHO_POD" -o jsonpath='{.spec.containers[*].name}' | grep -qw istio-proxy || fail_workload "threadforge-test/echo missing sidecar"

echo "[PASS] test workloads ensured"
