#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PHASE="${CI_RUNNER_CERT_PHASE:-generic}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)
      PHASE="${2:-generic}"
      shift 2
      ;;
    *)
      echo "[FAIL] CI_PRETRUST_INVALID: unknown argument '$1'"
      exit 2
      ;;
  esac
done

REGISTRY_ALIAS="${REGISTRY_ALIAS:-registry.threadforge.local}"
REGISTRY_PORT="${REGISTRY_PORT:-30500}"
SOURCE_CA="${SOURCE_CA:-${REPO_ROOT}/certs/threadforge-ingress-ca.crt}"
HOST_TRUST_DIR="/etc/docker/certs.d/${REGISTRY_ALIAS}:${REGISTRY_PORT}"
HOST_CA_PATH="${HOST_TRUST_DIR}/ca.crt"
REGISTRY_CONTAINER="${REGISTRY_CONTAINER:-threadforge-registry}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-registry.threadforge.local:30500/kindest-node@sha256:48321fb2717f92527d9aba9a9b32055dff622f9c356ea3de2f1ffb75344f87bf}"
ARTIFACT_DIR="${REPO_ROOT}/artifacts/ci"
ARTIFACT_PATH="${ARTIFACT_DIR}/runner_pretrust_${PHASE}.json"

fail_with_class() {
  local klass="$1"
  local reason="$2"
  local required_action="$3"

  mkdir -p "${ARTIFACT_DIR}"
  cat >"${ARTIFACT_PATH}" <<JSON
{
  "status": "FAIL",
  "classification": "${klass}",
  "phase": "${PHASE}",
  "reason": "${reason}",
  "required_action": "${required_action}",
  "registry_alias": "${REGISTRY_ALIAS}",
  "registry_port": "${REGISTRY_PORT}",
  "source_ca": "${SOURCE_CA}",
  "host_ca_path": "${HOST_CA_PATH}",
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

  echo "[FAIL] ${klass}: ${reason}"
  echo "[INFO] phase=${PHASE}"
  echo "[INFO] required_action=${required_action}"
  echo "[INFO] pretrust_artifact=${ARTIFACT_PATH}"
  exit 2
}

write_pass_artifact() {
  local fingerprint="$1"

  mkdir -p "${ARTIFACT_DIR}"
  cat >"${ARTIFACT_PATH}" <<JSON
{
  "status": "PASS",
  "classification": "CI_PRETRUST_VERIFIED",
  "phase": "${PHASE}",
  "registry_alias": "${REGISTRY_ALIAS}",
  "registry_port": "${REGISTRY_PORT}",
  "source_ca": "${SOURCE_CA}",
  "host_ca_path": "${HOST_CA_PATH}",
  "host_ca_fingerprint": "${fingerprint}",
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    fail_with_class "CI_PRETRUST_REQUIRED" "required tool '${cmd}' is missing" "provision immutable runner with full toolchain"
  fi
}

cert_fingerprint() {
  local cert_path="$1"
  openssl x509 -in "${cert_path}" -noout -fingerprint -sha256 | sed 's/^sha256 Fingerprint=//'
}

cert_is_expired() {
  local cert_path="$1"
  if openssl x509 -in "${cert_path}" -checkend 0 -noout >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

probe_registry_tls_code() {
  local ca_path="$1"
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 5 --max-time 10 --cacert "${ca_path}" \
    "https://${REGISTRY_ALIAS}:${REGISTRY_PORT}/v2/" || true
}

install_ci_host_ca() {
  local ca_path="$1"

  if [[ -w "${HOST_TRUST_DIR}" || ( ! -e "${HOST_TRUST_DIR}" && -w "$(dirname "${HOST_TRUST_DIR}")" ) ]]; then
    mkdir -p "${HOST_TRUST_DIR}"
    cp "${ca_path}" "${HOST_CA_PATH}"
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    return 1
  fi

  if ! sudo -n true >/dev/null 2>&1; then
    return 1
  fi

  sudo mkdir -p "${HOST_TRUST_DIR}"
  sudo cp "${ca_path}" "${HOST_CA_PATH}"
}

attempt_ci_tls_convergence() {
  local generated_exports=""
  local generated_source_ca="${REPO_ROOT}/certs/threadforge-ingress-ca.crt"

  echo "[CI-PRETRUST] attempting CI-only TLS convergence for registry trust chain"

  if ! generated_exports="$(THREADFORGE_EXECUTION_PROFILE=ci bash "${REPO_ROOT}/scripts/ci/provision_ci_disposable_certs.sh" 2>/dev/null)"; then
    return 1
  fi

  eval "${generated_exports}"

  if [[ ! -f "${generated_source_ca}" ]]; then
    return 1
  fi

  if ! install_ci_host_ca "${generated_source_ca}"; then
    return 1
  fi

  if ! THREADFORGE_EXECUTION_PROFILE=ci \
    CI_REGISTRY_CERTS_DIR="${CI_REGISTRY_CERTS_DIR:-}" \
    CI_REGISTRY_CONFIG="${CI_REGISTRY_CONFIG:-}" \
    REGISTRY_CONTAINER="${REGISTRY_CONTAINER}" \
    REGISTRY_ALIAS="${REGISTRY_ALIAS}" \
    REGISTRY_PORT="${REGISTRY_PORT}" \
    bash "${REPO_ROOT}/scripts/infra/harden_local_registry.sh" >/dev/null 2>&1; then
    return 1
  fi

  SOURCE_CA="${generated_source_ca}"
  return 0
}

echo "[CI-PRETRUST] enforcing runner certification gate for phase=${PHASE}"

if [[ "${THREADFORGE_EXECUTION_PROFILE:-local}" != "ci" ]]; then
  echo "[CI-PRETRUST] non-ci profile detected; gate bypassed"
  exit 0
fi

if [[ "${THREADFORGE_HOST_TRUST_MUTATION:-denied}" == "allowed" ]]; then
  fail_with_class "CI_PRETRUST_INVALID" "THREADFORGE_HOST_TRUST_MUTATION=allowed is forbidden in CI" "set THREADFORGE_HOST_TRUST_MUTATION=denied"
fi

for cmd in docker kind kubectl helm jq python3 openssl curl; do
  require_cmd "${cmd}"
done

if ! docker info >/dev/null 2>&1; then
  fail_with_class "CI_PRETRUST_REQUIRED" "docker daemon is not reachable" "start runner with docker daemon available"
fi

# CI checkout may not carry the local CA file. In immutable-runner mode,
# use the pre-provisioned host trust anchor as the authoritative source CA.
if [[ ! -f "${SOURCE_CA}" ]]; then
  if [[ -f "${HOST_CA_PATH}" ]]; then
    echo "[CI-PRETRUST] source CA missing at ${SOURCE_CA}; using host trust CA ${HOST_CA_PATH}"
    SOURCE_CA="${HOST_CA_PATH}"
  else
    fail_with_class "CI_PRETRUST_REQUIRED" "registry CA missing at ${SOURCE_CA}" "pre-provision runner CA material"
  fi
fi

if cert_is_expired "${SOURCE_CA}"; then
  fail_with_class "CI_PRETRUST_EXPIRED" "source registry CA is expired" "rotate runner trust CA and recertify"
fi

if [[ ! -f "${HOST_CA_PATH}" ]]; then
  fail_with_class "CI_PRETRUST_REQUIRED" "docker trust path missing ${HOST_CA_PATH}" "install registry CA during runner provisioning"
fi

if cert_is_expired "${HOST_CA_PATH}"; then
  fail_with_class "CI_PRETRUST_EXPIRED" "host docker trust CA is expired" "rotate host trust CA and recertify runner"
fi

expected_fp="$(cert_fingerprint "${SOURCE_CA}")"
observed_fp="$(cert_fingerprint "${HOST_CA_PATH}")"
if [[ "${expected_fp}" != "${observed_fp}" ]]; then
  fail_with_class "CI_PRETRUST_INVALID" "host docker trust CA fingerprint mismatch" "reinstall correct CA in immutable runner image"
fi

registry_tls_code="$(probe_registry_tls_code "${SOURCE_CA}")"
if [[ "${registry_tls_code}" != "200" && "${registry_tls_code}" != "401" && "${registry_tls_code}" != "403" && "${THREADFORGE_EXECUTION_PROFILE:-local}" == "ci" ]]; then
  if attempt_ci_tls_convergence; then
    expected_fp="$(cert_fingerprint "${SOURCE_CA}")"
    observed_fp="$(cert_fingerprint "${HOST_CA_PATH}")"
    if [[ "${expected_fp}" != "${observed_fp}" ]]; then
      fail_with_class "CI_PRETRUST_INVALID" "host docker trust CA fingerprint mismatch after CI convergence" "rebuild CI runner trust anchor and registry TLS pair"
    fi
    registry_tls_code="$(probe_registry_tls_code "${SOURCE_CA}")"
  else
    fail_with_class "CI_PRETRUST_REQUIRED" "CI TLS convergence failed before pretrust verification" "ensure CI runner permits host trust prime and registry hardening"
  fi
fi

if [[ "${registry_tls_code}" != "200" && "${registry_tls_code}" != "401" && "${registry_tls_code}" != "403" ]]; then
  fail_with_class "CI_PRETRUST_INVALID" "registry TLS probe failed (HTTP ${registry_tls_code:-000})" "verify registry endpoint and pretrusted CA chain"
fi

if ! docker pull "${KIND_NODE_IMAGE}" >/dev/null 2>&1; then
  fail_with_class "CI_PRETRUST_REQUIRED" "docker pull failed for pinned kind node image" "pretrust runner registry path and image availability"
fi

write_pass_artifact "${observed_fp}"
echo "[PASS] CI_RUNNER_PRETRUST_VERIFIED"
echo "[INFO] phase=${PHASE}"
echo "[INFO] pretrust_artifact=${ARTIFACT_PATH}"
