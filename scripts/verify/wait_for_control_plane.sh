#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TIMEOUT_SECONDS="${CONTROL_PLANE_TIMEOUT_SECONDS:-600}"
INTERVAL_SECONDS="${CONTROL_PLANE_INTERVAL_SECONDS:-5}"
deadline="$(( $(date +%s) + TIMEOUT_SECONDS ))"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

fail() {
  echo "[FAIL] CONTROL PLANE NOT READY — $1"
  exit 2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 not found"
}

require_cmd kubectl
require_cmd jq

retry_until() {
  local description="$1"
  shift
  local output=""

  while [ "$(date +%s)" -lt "$deadline" ]; do
    if output="$("$@" 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    fi
    sleep "$INTERVAL_SECONDS"
  done

  printf '%s\n' "$output"
  fail "$description"
}

spire_server_ready() {
  local pod
  pod="$(select_active_spire_server_pod spire-system)"
  [ -n "$pod" ] || return 1
  kubectl wait --for=condition=Ready "pod/$pod" -n spire-system --timeout="${INTERVAL_SECONDS}s"
}

echo "[control-plane] waiting for control plane readiness"
# Canonical control-plane convergence gate.
# Proof witnesses and bootstrap wrappers consume this gate rather than
# re-implementing readiness, retry, or settle logic locally.

webhook_endpoints_ready() {
  local addresses ports

  kubectl get svc kyverno-svc -n kyverno >/dev/null 2>&1 || return 1
  addresses="$(kubectl get endpoints kyverno-svc -n kyverno -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  ports="$(kubectl get endpoints kyverno-svc -n kyverno -o jsonpath='{.subsets[*].ports[*].port}' 2>/dev/null || true)"
  if [ -z "$addresses" ] || [ -z "$ports" ]; then
    return 1
  fi

  echo "[control-plane] kyverno webhook endpoints: $addresses"
  return 0
}

retry_until "kyverno-admission-controller unavailable" \
  kubectl wait --for=condition=Available deploy/kyverno-admission-controller -n kyverno --timeout="${INTERVAL_SECONDS}s"
retry_until "istiod unavailable" \
  kubectl wait --for=condition=Available deploy/istiod -n istio-system --timeout="${INTERVAL_SECONDS}s"
retry_until "active spire-server pod not ready" \
  spire_server_ready
retry_until "spire-agent pod not ready" \
  kubectl wait --for=condition=Ready pod -n spire-system -l app=spire-agent --timeout="${INTERVAL_SECONDS}s"
retry_until "kube-dns pods not ready" \
  kubectl wait --for=condition=Ready pod -n kube-system -l k8s-app=kube-dns --timeout="${INTERVAL_SECONDS}s"
retry_until "kube-apiserver pod not ready" \
  kubectl wait --for=condition=Ready pod -n kube-system -l component=kube-apiserver --timeout="${INTERVAL_SECONDS}s"
retry_until "kube-controller-manager pod not ready" \
  kubectl wait --for=condition=Ready pod -n kube-system -l component=kube-controller-manager --timeout="${INTERVAL_SECONDS}s"
retry_until "kube-scheduler pod not ready" \
  kubectl wait --for=condition=Ready pod -n kube-system -l component=kube-scheduler --timeout="${INTERVAL_SECONDS}s"
retry_until "etcd pod not ready" \
  kubectl wait --for=condition=Ready pod -n kube-system -l component=etcd --timeout="${INTERVAL_SECONDS}s"

if kubectl get ns cert-manager >/dev/null 2>&1; then
  retry_until "cert-manager deployment unavailable" \
    kubectl wait --for=condition=Available deploy/cert-manager -n cert-manager --timeout="${INTERVAL_SECONDS}s"
  retry_until "cert-manager-cainjector deployment unavailable" \
    kubectl wait --for=condition=Available deploy/cert-manager-cainjector -n cert-manager --timeout="${INTERVAL_SECONDS}s"
  retry_until "cert-manager-webhook deployment unavailable" \
    kubectl wait --for=condition=Available deploy/cert-manager-webhook -n cert-manager --timeout="${INTERVAL_SECONDS}s"
fi

echo "[control-plane] verifying webhook endpoint reachability"
retry_until "kyverno webhook endpoint did not respond" \
  webhook_endpoints_ready

echo "[control-plane] verifying kyverno webhook dry-run readiness"
env TEST_NAMESPACE=istio-system bash "$REPO_ROOT/scripts/verify/verify_webhook_ca_integrity.sh" >/dev/null 2>&1 \
  || fail "kyverno webhook dry-run probe did not respond"

echo "[PASS] control plane readiness gate satisfied"
