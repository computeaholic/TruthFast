#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL_REGISTRY="${THREADFORGE_CANONICAL_REGISTRY:-registry.threadforge.local:30500}"

fail() {
  echo "[FAIL] PROOF_ENV_DRIFT: $*"
  exit 2
}

pass() {
  echo "[PASS] $*"
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "missing required command: ${cmd}"
}

check_local_env_contract() {
  if [[ -n "${COSIGN_EXPERIMENTAL:-}" ]]; then
    fail "COSIGN_EXPERIMENTAL is forbidden in proof environment"
  fi

  # Enforce unset COSIGN_REPOSITORY: in this runtime it forces HTTP transport
  # for Kyverno image verification when set to host:port.
  if [[ -n "${COSIGN_REPOSITORY:-}" ]]; then
    fail "COSIGN_REPOSITORY must be unset in proof environment"
  fi

  if [[ -n "${THREADFORGE_REGISTRY:-}" && "${THREADFORGE_REGISTRY}" != "${CANONICAL_REGISTRY}" ]]; then
    fail "THREADFORGE_REGISTRY=${THREADFORGE_REGISTRY} does not match canonical ${CANONICAL_REGISTRY}"
  fi

  pass "proof env forbids hidden cosign overrides"
}

check_cluster_env_contract() {
  local cluster_repo
  local cluster_cosign_experimental

  cluster_repo="$(kubectl -n kyverno get deployment kyverno-admission-controller -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="COSIGN_REPOSITORY")].value}' 2>/dev/null || true)"
  cluster_cosign_experimental="$(kubectl -n kyverno get deployment kyverno-admission-controller -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="COSIGN_EXPERIMENTAL")].value}' 2>/dev/null || true)"

  if [[ -n "$cluster_repo" ]]; then
    fail "cluster COSIGN_REPOSITORY must be unset on kyverno-admission-controller (got: ${cluster_repo})"
  fi

  if [[ -n "$cluster_cosign_experimental" ]]; then
    fail "cluster COSIGN_EXPERIMENTAL must be unset (got: ${cluster_cosign_experimental})"
  fi

  pass "proof env matches kyverno admission signing env"
}

check_proof_surface_forbidden_patterns() {
  local -a files=(
    "Makefile"
    "scripts/prove_system.sh"
    "scripts/proof/sign_proof_artifacts.sh"
    "scripts/lib/ensure_cosign_keys.sh"
    "scripts/security/generate_cosign_keys.sh"
  )

  # Fail only on real override vectors. Plain references (for explicit guards,
  # jsonpath reads, comments) are not drift.
  local -a forbidden_regexes=(
    '(^|[[:space:];])((export[[:space:]]+)?COSIGN_EXPERIMENTAL[[:space:]]*=)'
    '--allow-insecure-registry'
    '--insecure-ignore-tlog'
    '--insecure-ignore-sct'
    '--rekor-url'
    '--registry-referrers-mode'
    '--tlog-upload=false'
    '(^|[[:space:];])((export[[:space:]]+)?THREADFORGE_REGISTRY[[:space:]]*=)'
    '(^|[[:space:];])((export[[:space:]]+)?COSIGN_REPOSITORY[[:space:]]*=)'
  )

  local regex
  local f
  for regex in "${forbidden_regexes[@]}"; do
    for f in "${files[@]}"; do
      if grep -Eq -- "$regex" "$REPO_ROOT/$f"; then
        fail "forbidden proof-path override detected: regex '$regex' in $f"
      fi
    done
  done

  pass "proof-path scripts contain no forbidden cosign overrides"
}

main() {
  require_cmd kubectl
  require_cmd grep

  check_local_env_contract
  check_cluster_env_contract
  check_proof_surface_forbidden_patterns

  echo "[PASS] PROOF_ENV_CONTRACT"
}

main "$@"
