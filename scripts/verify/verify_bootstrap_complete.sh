#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "[FAIL] BOOTSTRAP_INCOMPLETE"
  exit 2
}

step() {
  echo "[STEP] $1"
}

pass() {
  echo "[PASS] $1"
}

command -v kubectl >/dev/null 2>&1 || fail

step "bootstrap-complete"

for namespace in istio-system kyverno spire-system threadforge-test; do
  kubectl get namespace "$namespace" >/dev/null 2>&1 || fail
done

kubectl rollout status deployment/istiod -n istio-system --timeout=180s >/dev/null 2>&1 || fail
kubectl rollout status statefulset/spire-server -n spire-system --timeout=180s >/dev/null 2>&1 || fail

for deployment in \
  kyverno-admission-controller \
  kyverno-background-controller \
  kyverno-cleanup-controller \
  kyverno-reports-controller; do
  kubectl rollout status deployment/"$deployment" -n kyverno --timeout=180s >/dev/null 2>&1 || fail
done

bash "$REPO_ROOT/scripts/verify/verify_registry_tls_trust.sh" >/dev/null 2>&1 || fail
bash "$REPO_ROOT/scripts/verify/ensure_test_workload.sh" >/dev/null 2>&1 || fail

pass "bootstrap-complete"
