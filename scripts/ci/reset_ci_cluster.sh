#!/usr/bin/env bash
# CI Cluster Reset — ThreadForge
# Purpose: Destroy any existing kind cluster and create a clean one.
#          This script enforces reset/bootstrap phase separation and must not
#          perform bootstrap, workload deployment, or runtime image pinning.
#
# Called by .github/workflows/ci-proof.yml as the very first step of a proof run.
#
# Requirements on the runner:
#   - kind    (v0.22.0)
#   - docker  (containerd runtime)
#   - kubectl, helm, cosign, istioctl, jq, python3, openssl
#   - threadforge-registry Docker container pre-running on port 30500
#
# Exit codes:
#   0  cluster created, infra bootstrapped, ready for `make proof`
#   1  fatal error — CI must abort
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-threadforge}"
KIND_CONFIG="${KIND_CONFIG:-${REPO_ROOT}/platform/build/kind/kind-config.yaml}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-registry.threadforge.local:30500/kindest-node@sha256:48321fb2717f92527d9aba9a9b32055dff622f9c356ea3de2f1ffb75344f87bf}"
REGISTRY_CONTAINER="${REGISTRY_CONTAINER:-threadforge-registry}"
REGISTRY_ALIAS="registry.threadforge.local"
REGISTRY_PORT="${REGISTRY_PORT:-30500}"
THREADFORGE_REGISTRY_USER="${THREADFORGE_REGISTRY_USER:-threadforge}"
THREADFORGE_REGISTRY_PASSWORD="${THREADFORGE_REGISTRY_PASSWORD:-threadforge-dev-password}"
HARDEN_LOCAL_REGISTRY_SCRIPT="${REPO_ROOT}/scripts/infra/harden_local_registry.sh"
KIND_NETWORK="kind"
CANONICAL_KUBECONFIG_PATH="${HOME}/.kube/config"
REQUESTED_KUBECONFIG_PATH="${KUBECONFIG:-}"
KUBECONFIG_PATH="${CANONICAL_KUBECONFIG_PATH}"
CI_RESET_BOOTSTRAP="${CI_RESET_BOOTSTRAP:-false}"
CI_RESET_RUNTIME_INIT="${CI_RESET_RUNTIME_INIT:-false}"
THREADFORGE_HOST_TRUST_MUTATION="${THREADFORGE_HOST_TRUST_MUTATION:-denied}"
THREADFORGE_CI_HOST_TRUST_MODE="${THREADFORGE_CI_HOST_TRUST_MODE:-verify-only}"
TRUST_ROOT_ARTIFACT="${REPO_ROOT}/artifacts/trust/root.pem"
TRUST_ROOT_EVIDENCE="${REPO_ROOT}/artifacts/trust/root_consistency_check.json"

# shellcheck source=scripts/lib/bootstrap_timeline.sh
source "${REPO_ROOT}/scripts/lib/bootstrap_timeline.sh"
tf_bt_init "${REPO_ROOT}"
TF_RESET_ACTIVE_PHASE="cluster-reset"
tf_bt_phase_start "cluster-reset" "reset script entry"

# ── Helpers ─────────────────────────────────────────────────────────────────
fail() {
  tf_bt_phase_failure "${TF_RESET_ACTIVE_PHASE:-cluster-reset}" "$*"
  tf_bt_phase_end "${TF_RESET_ACTIVE_PHASE:-cluster-reset}" "FAIL" "reset failure"
  echo "[CI-RESET] FAIL: $*" >&2
  exit 10
}
step() { echo "[CI-RESET] ── $* ──"; }

emit_sudo_required_and_exit() {
  local purpose="$1"
  local stdin_tty="false"
  local stdout_tty="false"

  [[ -t 0 ]] && stdin_tty="true"
  [[ -t 1 ]] && stdout_tty="true"

  echo "[FAIL] SUDO_REQUIRED: ${purpose} requires noninteractive sudo authority"
  echo "[INFO] sudo_tty_stdin_attached=${stdin_tty}"
  echo "[INFO] sudo_tty_stdout_attached=${stdout_tty}"
  echo "[INFO] required_probe: sudo -n true"
  exit 2
}

ensure_sudo_noninteractive_or_fail() {
  local purpose="$1"

  if [[ "${THREADFORGE_EXECUTION_PROFILE:-local}" == "ci" ]]; then
    echo "[FAIL] CI_HOST_MUTATION_DENIED: sudo path reached in CI (${purpose})"
    echo "[INFO] classification=CI_HOST_MUTATION_DENIED"
    exit 2
  fi

  command -v sudo >/dev/null 2>&1 || emit_sudo_required_and_exit "$purpose"
  sudo -n true >/dev/null 2>&1 || emit_sudo_required_and_exit "$purpose"
  echo "[CI-RESET] [PASS] noninteractive sudo authority verified (${purpose})"
}

install_host_registry_ca_trust() {
  local trust_dir="/etc/docker/certs.d/${REGISTRY_ALIAS}:${REGISTRY_PORT}"
  local ca_src="${REPO_ROOT}/certs/threadforge-ingress-ca.crt"

  if [[ "${THREADFORGE_EXECUTION_PROFILE:-local}" == "ci" ]]; then
    echo "[FAIL] CI_HOST_MUTATION_DENIED: install_host_registry_ca_trust is forbidden in CI"
    echo "[INFO] classification=CI_HOST_MUTATION_DENIED"
    exit 2
  fi

  [[ -f "${ca_src}" ]] || fail "CI registry CA missing at ${ca_src}"
  step "Installing CI registry CA into host Docker trust store"

  if mkdir -p "${trust_dir}" 2>/dev/null && cp "${ca_src}" "${trust_dir}/ca.crt" 2>/dev/null; then
    echo "[CI-RESET] [PASS] host Docker trust updated at ${trust_dir}/ca.crt"
    return 0
  fi

  ensure_sudo_noninteractive_or_fail "host Docker trust mutation"
  sudo mkdir -p "${trust_dir}"
  sudo cp "${ca_src}" "${trust_dir}/ca.crt"
  echo "[CI-RESET] [PASS] host Docker trust updated at ${trust_dir}/ca.crt"
}

verify_ci_host_registry_trust() {
  step "CI host trust classification (verify-only, no mutation)"
  if REGISTRY_ALIAS="${REGISTRY_ALIAS}" REGISTRY_PORT="${REGISTRY_PORT}" \
    SOURCE_CA="${REPO_ROOT}/certs/threadforge-ingress-ca.crt" \
    bash "${REPO_ROOT}/scripts/infra/host_trust_prime.sh" --mode verify; then
    echo "[CI-RESET] [PASS] CI host trust verified"
    return 0
  fi

  echo "[CI-RESET] [WARN] CI host trust verification failed; mutation is prohibited in CI"
  echo "[CI-RESET] [INFO] classification=CI_HOST_TRUST_REQUIRED_NO_MUTATION"
  return 1
}

if [[ "${THREADFORGE_EXECUTION_PROFILE:-local}" == "ci" ]]; then
  echo "[CI-RESET] [INFO] CI_DISPOSABLE_PROFILE=true"
  echo "[CI-RESET] [INFO] canonical reference retained: ${HARDEN_LOCAL_REGISTRY_SCRIPT} (execution denied in CI profile)"
  if [[ "${THREADFORGE_CI_HOST_TRUST_MODE}" != "verify-only" ]]; then
    fail "invalid THREADFORGE_CI_HOST_TRUST_MODE='${THREADFORGE_CI_HOST_TRUST_MODE}' (expected verify-only)"
  fi
  if [[ "${THREADFORGE_HOST_TRUST_MUTATION}" == "allowed" ]]; then
    echo "[FAIL] CI_HOST_MUTATION_DENIED: THREADFORGE_HOST_TRUST_MUTATION=allowed is forbidden in CI"
    echo "[INFO] classification=CI_HOST_MUTATION_DENIED"
    exit 2
  fi
  step "Enforcing CI pretrust baseline (mutation denied)"
  CI_RUNNER_CERT_PHASE="cluster-reset" bash "${REPO_ROOT}/scripts/ci/runner_pretrust_gate.sh" --phase cluster-reset
  verify_ci_host_registry_trust
else
  echo "[cluster-reset] local execution profile — using repo-managed registry certs"
  if [[ "${THREADFORGE_HOST_TRUST_MUTATION}" == "allowed" ]]; then
    echo "[cluster-reset] local host trust mutation allowed by THREADFORGE_HOST_TRUST_MUTATION=allowed"
    install_host_registry_ca_trust
  else
    echo "[cluster-reset] local host trust verify-only mode (no mutation)"
    bash "${REPO_ROOT}/scripts/infra/host_trust_prime.sh" --mode verify
  fi
fi

echo "[cluster] verifying node image exists in registry"
docker pull "${KIND_NODE_IMAGE}" >/dev/null 2>&1 || {
  if [[ "${THREADFORGE_EXECUTION_PROFILE:-local}" == "ci" ]]; then
    echo "[FAIL] CI_DISPOSABLE_TRUST_PREREQ_FAILED: node image pull failed without host trust mutation"
    echo "[INFO] classification=CI_PRETRUST_REQUIRED"
    echo "[INFO] expected_host_trust_path=/etc/docker/certs.d/${REGISTRY_ALIAS}:${REGISTRY_PORT}/ca.crt"
    echo "[INFO] required_action=pre-bake CI runner trust or provide trusted registry endpoint"
    exit 2
  fi
  echo "[FAIL] required node image missing from registry: ${KIND_NODE_IMAGE}"
  exit 2
}

[[ "${CI_RESET_BOOTSTRAP}" == "false" ]] || fail "cluster-reset cannot run bootstrap logic; run 'make infra-bootstrap' as a separate phase"
[[ "${CI_RESET_RUNTIME_INIT}" == "false" ]] || fail "cluster-reset cannot run runtime-init logic; run runtime initialization from bootstrap phase"

wait_for_api() {
  local attempts=60 i
  TF_RESET_ACTIVE_PHASE="api-readiness"
  tf_bt_phase_start "api-readiness" "waiting for kubernetes api"
  step "Waiting for Kubernetes API server"
  for i in $(seq 1 $attempts); do
    if kubectl version --request-timeout=5s >/dev/null 2>&1; then
      tf_bt_phase_progress "api-readiness" "api ready on attempt ${i}"
      TF_BT_PHASE_RETRY_COUNT["api-readiness"]="$((i - 1))"
      tf_bt_phase_end "api-readiness" "PASS" "api readiness complete"
      TF_RESET_ACTIVE_PHASE="cluster-reset"
      echo "[CI-RESET] API server ready (attempt $i)"
      return 0
    fi
    tf_bt_phase_progress "api-readiness" "api not ready on attempt ${i}"
    sleep 3
  done
  tf_bt_phase_failure "api-readiness" "kubernetes api did not become ready"
  TF_BT_PHASE_RETRY_COUNT["api-readiness"]="$attempts"
  tf_bt_phase_end "api-readiness" "FAIL" "api readiness timed out"
  TF_RESET_ACTIVE_PHASE="cluster-reset"
  fail "Kubernetes API did not become ready within $((attempts * 3))s"
}

assert_disposable_context_ready() {
  local expected_context current_context attempts=60 i
  expected_context="kind-${KIND_CLUSTER_NAME}"

  step "Validating disposable kube context"
  current_context="$(kubectl config current-context 2>/dev/null || true)"
  [[ -n "$current_context" ]] || fail "kubectl current-context is unset after kubeconfig export"
  [[ "$current_context" == "$expected_context" ]] || fail "expected current-context '${expected_context}' but found '${current_context}'"

  for i in $(seq 1 $attempts); do
    if kubectl cluster-info --request-timeout=5s >/dev/null 2>&1 && \
       kubectl wait --for=condition=Ready node --all --timeout=5s >/dev/null 2>&1; then
      echo "[CI-RESET] [PASS] disposable context ready: ${current_context}"
      return 0
    fi
    sleep 1
  done
  fail "cluster-info or node Ready failed within $((attempts))s"
}

assert_kubeconfig_endpoint_matches_kind() {
  local expected_host_port expected_endpoint actual_endpoint
  expected_host_port="$(docker port "${KIND_CLUSTER_NAME}-control-plane" 6443/tcp 2>/dev/null | head -n1 | tr -d '[:space:]')"
  [[ -n "$expected_host_port" ]] || fail "unable to resolve kind API server host port"
  expected_endpoint="https://${expected_host_port}"

  actual_endpoint="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  [[ -n "$actual_endpoint" ]] || fail "unable to read kubeconfig cluster server endpoint"
  [[ "$actual_endpoint" == "$expected_endpoint" ]] || fail "kubeconfig endpoint drift detected: expected ${expected_endpoint}, got ${actual_endpoint}"

  if ! kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
    fail "kubeconfig endpoint points to unreachable API server: ${actual_endpoint}"
  fi

  echo "[CI-RESET] [PASS] kubeconfig endpoint matches live kind API: ${actual_endpoint}"
}

# FIX 2: Assert only baseline namespaces/CRDs exist on a freshly-created cluster.
assert_clean_cluster() {
  step "FIX 2 — assert clean cluster baseline (namespaces / CRDs / SPIRE)"

  # Expected namespaces immediately after `kind create cluster` (before bootstrap)
  local expected_ns=(default kube-node-lease kube-public kube-system local-path-storage)
  local actual_ns
  mapfile -t actual_ns < <(kubectl get ns --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | sort)

  for ns in "${actual_ns[@]}"; do
    local found=0
    for exp in "${expected_ns[@]}"; do
      [[ "$ns" == "$exp" ]] && found=1 && break
    done
    [[ $found -eq 1 ]] || fail "FIX 2: unexpected namespace '${ns}' on fresh cluster — leftover state detected"
  done

  local crd_count
  crd_count=$(kubectl get crds --no-headers 2>/dev/null | wc -l)
  [[ $crd_count -eq 0 ]] || fail "FIX 2: ${crd_count} CRD(s) found on fresh cluster — leftover state detected"

  echo "[CI-RESET] [PASS] FIX 2 — clean baseline: ns={${expected_ns[*]}}, CRDs=0"
}

assert_reset_boundary_namespaces_absent() {
  step "Hard guard — reset phase must not contain application namespaces"

  if kubectl get ns --no-headers -o custom-columns=NAME:.metadata.name \
    | grep -E '^(istio-system|spire-system|observability|threadforge-test)$' >/dev/null; then
    kubectl get ns --no-headers -o custom-columns=NAME:.metadata.name \
      | grep -E '^(istio-system|spire-system|observability|threadforge-test)$' || true
    fail "reset phase contamination: application namespaces detected"
  fi

  echo "[CI-RESET] [PASS] reset boundary guard: no istio/spire/observability/workload namespaces present"
}

clear_stale_trust_root_artifacts() {
  step "Clearing stale trust-root artifacts"
  rm -f "$TRUST_ROOT_ARTIFACT" "$TRUST_ROOT_EVIDENCE"
  echo "[CI-RESET] [PASS] stale trust-root artifacts removed"
}

# ── FIX 1: Destroy old cluster (no leftover state) ──────────────────────────
step "FIX 1 — destroy existing kind cluster (no leftover certs/pods)"
kind delete cluster --name "${KIND_CLUSTER_NAME}" 2>/dev/null || true

# The kind Docker network is also destroyed on delete.
# The registry container needs to be reconnected after cluster creation.

# ── FIX 1: Create fresh cluster ─────────────────────────────────────────────
step "FIX 1 — create fresh kind cluster (name=${KIND_CLUSTER_NAME})"
kind create cluster \
  --name "${KIND_CLUSTER_NAME}" \
  --image "${KIND_NODE_IMAGE}" \
  --config "${KIND_CONFIG}" \
  --wait 120s

# ── FIX 5: Export kubeconfig explicitly — no env-dependent paths ────────────
step "FIX 5 — export kubeconfig to ${KUBECONFIG_PATH}"
if [[ -n "${REQUESTED_KUBECONFIG_PATH}" && "${REQUESTED_KUBECONFIG_PATH}" != "${CANONICAL_KUBECONFIG_PATH}" ]]; then
  echo "[CI-RESET] [WARN] ignoring non-canonical KUBECONFIG=${REQUESTED_KUBECONFIG_PATH}; forcing ${CANONICAL_KUBECONFIG_PATH}"
fi
mkdir -p "$(dirname "${KUBECONFIG_PATH}")"
kind export kubeconfig --name "${KIND_CLUSTER_NAME}" --kubeconfig "${KUBECONFIG_PATH}"
export KUBECONFIG="${KUBECONFIG_PATH}"

wait_for_api
assert_disposable_context_ready
assert_kubeconfig_endpoint_matches_kind

assert_clean_cluster  # FIX 2

# ── FIX 1: Reconnect registry with its DNS alias ────────────────────────────
step "FIX 1 — reconnect registry container to kind network"
if ! docker inspect "${REGISTRY_CONTAINER}" >/dev/null 2>&1; then
  fail "Registry container '${REGISTRY_CONTAINER}' is not running. Start it with: docker run -d --restart=always -p 30500:30500 --name threadforge-registry registry:2"
fi

# Disconnect first in case of stale network membership
docker network disconnect "${KIND_NETWORK}" "${REGISTRY_CONTAINER}" 2>/dev/null || true
docker network connect \
  --alias "${REGISTRY_ALIAS}" \
  "${KIND_NETWORK}" \
  "${REGISTRY_CONTAINER}"

echo "[CI-RESET] Registry ${REGISTRY_CONTAINER} connected to ${KIND_NETWORK} as ${REGISTRY_ALIAS}"

# Verify registry is reachable from the kind node (sanity check)
# OPT 2: poll at 1s intervals instead of 3s
step "Verifying registry reachability from kind node"
for _i in $(seq 1 15); do
  status="$(docker exec "${KIND_CLUSTER_NAME}-control-plane" \
       sh -c "curl -sS -k -o /dev/null -w '%{http_code}' https://${REGISTRY_ALIAS}:30500/v2/" 2>/dev/null || true)"
  if [[ "${status}" == "200" || "${status}" == "401" || "${status}" == "403" ]]; then
    echo "[CI-RESET] [PASS] registry reachable from kind node"
    break
  fi
  sleep 1
done

assert_reset_boundary_namespaces_absent
clear_stale_trust_root_artifacts

echo "[CI-RESET] reset completed; bootstrap must run as a separate phase"

echo ""
echo "[CI-RESET] ═══════════════════════════════════════════════════════"
echo "[CI-RESET] CI RESET HARDENED — PHASE SEPARATION ENFORCED"
echo "[CI-RESET] cluster=${KIND_CLUSTER_NAME} infra=not-bootstrapped"
echo "[CI-RESET] guarantees: clean-baseline(FIX2) reset-boundary(no app namespaces) registry-source-of-truth"
echo "[CI-RESET] ═══════════════════════════════════════════════════════"
tf_bt_phase_end "cluster-reset" "PASS" "reset completed"
