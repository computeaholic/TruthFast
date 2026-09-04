#!/usr/bin/env bash
# CI Disposable Cert Provisioner — ThreadForge
#
# Purpose:
#   Generate ephemeral CA and registry TLS certs for the CI disposable topology,
#   writing all output to LOCAL DISK ONLY (no docker exec required).
#
#   The existing registry container may be in any state (running, restarting,
#   or stopped) — this script does NOT touch it.  It emits two env-var exports
#   that the caller (reset_ci_cluster.sh) passes to harden_local_registry.sh:
#
#     CI_REGISTRY_CERTS_DIR   — directory containing registry.crt + registry.key
#     CI_REGISTRY_CONFIG      — path to the TLS-enabled registry config.yml
#
#   harden_local_registry.sh reads these in CI mode and uses the pre-provisioned
#   files when (re-)creating the registry container, bypassing the
#   docker-exec-based extraction path that fails when the container is unhealthy.
#
# This is NOT authoritative runtime cert generation.
# All certs produced here are:
#   - valid for 1 day
#   - scoped to the CI disposable execution environment
#   - NOT persisted across runs (gitignored certs/ directory)
#
# Outputs (printed to stdout for eval by caller):
#   export CI_REGISTRY_CERTS_DIR=<path>
#   export CI_REGISTRY_CONFIG=<path>
#
# Requirements:
#   - openssl
#   - THREADFORGE_EXECUTION_PROFILE=ci (enforced)
#
# Exit codes:
#   0  certs generated; exports printed to stdout
#   1  fatal — CI must abort
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REGISTRY_ALIAS="${REGISTRY_ALIAS:-registry.threadforge.local}"
REGISTRY_PORT="${REGISTRY_PORT:-30500}"
REGISTRY_CONTAINER="${REGISTRY_CONTAINER:-threadforge-registry}"
CI_CERTS_OUTDIR="${REPO_ROOT}/artifacts/registry-certs-ci"
CI_REGISTRY_CONFIG_DIR="${REPO_ROOT}/artifacts/registry-runtime"
CI_REGISTRY_CONFIG="${CI_REGISTRY_CONFIG_DIR}/${REGISTRY_CONTAINER}-config.yml"

fail() { echo "[CI-CERT-PROVISION] FAIL: $*" >&2; exit 1; }
step() { echo "[CI-CERT-PROVISION] ── $* ──" >&2; }

# Enforce CI-only execution
if [[ "${THREADFORGE_EXECUTION_PROFILE:-local}" != "ci" ]]; then
  fail "provision_ci_disposable_certs must only run with THREADFORGE_EXECUTION_PROFILE=ci"
fi

if ! command -v openssl >/dev/null 2>&1; then
  fail "openssl is required to generate CI disposable certs"
fi

step "Generating CI disposable CA cert (1-day validity)"

mkdir -p "${REPO_ROOT}/certs"
mkdir -p "${CI_CERTS_OUTDIR}"
mkdir -p "${CI_REGISTRY_CONFIG_DIR}"

# Generate ephemeral CA key + self-signed cert.
# Overwrites any stale cert from a previous CI run — disposable topology must
# never reuse CA material across runs.
openssl req \
  -new -x509 \
  -newkey rsa:3072 \
  -sha256 \
  -keyout "${REPO_ROOT}/certs/registry-ca.key" \
  -out "${REPO_ROOT}/certs/threadforge-ingress-ca.crt" \
  -days 1 \
  -nodes \
  -subj '/CN=threadforge-ingress-ca-ci' \
  -addext 'basicConstraints=critical,CA:TRUE' \
  2>/dev/null

if ! openssl x509 -in "${REPO_ROOT}/certs/threadforge-ingress-ca.crt" -noout 2>/dev/null; then
  fail "generated CA cert failed openssl verification"
fi

echo "[CI-CERT-PROVISION] CA cert: ${REPO_ROOT}/certs/threadforge-ingress-ca.crt" >&2

step "Generating CI disposable registry TLS cert (1-day validity)"

openssl genrsa -out "${CI_CERTS_OUTDIR}/registry.key" 3072 2>/dev/null

openssl req \
  -new \
  -key "${CI_CERTS_OUTDIR}/registry.key" \
  -out "${CI_CERTS_OUTDIR}/registry.csr" \
  -subj "/CN=${REGISTRY_ALIAS}" \
  2>/dev/null

openssl x509 -req \
  -in "${CI_CERTS_OUTDIR}/registry.csr" \
  -CA "${REPO_ROOT}/certs/threadforge-ingress-ca.crt" \
  -CAkey "${REPO_ROOT}/certs/registry-ca.key" \
  -CAcreateserial \
  -out "${CI_CERTS_OUTDIR}/registry.crt" \
  -days 1 \
  -sha256 \
  -extfile <(printf 'subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1\n' "${REGISTRY_ALIAS}") \
  2>/dev/null

if ! openssl verify -CAfile "${REPO_ROOT}/certs/threadforge-ingress-ca.crt" "${CI_CERTS_OUTDIR}/registry.crt" >/dev/null 2>&1; then
  fail "generated registry TLS cert failed CA verification"
fi

echo "[CI-CERT-PROVISION] registry TLS cert: ${CI_CERTS_OUTDIR}/registry.crt" >&2

step "Writing CI disposable registry TLS config"

# Write a TLS-enabled registry config that harden_local_registry.sh will use
# (via CI_REGISTRY_CONFIG env var) when restarting the registry container.
# The container port must match REGISTRY_PORT (30500) since docker run uses
# -p ${REGISTRY_PORT}:${REGISTRY_PORT}.
cat > "${CI_REGISTRY_CONFIG}" <<REGCFG
version: 0.1
log:
  fields:
    service: registry
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/registry
  delete:
    enabled: true
http:
  addr: :${REGISTRY_PORT}
  tls:
    certificate: /certs/registry.crt
    key: /certs/registry.key
  headers:
    X-Content-Type-Options: [nosniff]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
REGCFG

echo "[CI-CERT-PROVISION] registry config: ${CI_REGISTRY_CONFIG}" >&2

echo "" >&2
echo "[CI-CERT-PROVISION] ════════════════════════════════════════════" >&2
echo "[CI-CERT-PROVISION] CI DISPOSABLE CERT TOPOLOGY PROVISIONED (local disk)" >&2
echo "[CI-CERT-PROVISION] CA:     certs/threadforge-ingress-ca.crt (1-day ephemeral)" >&2
echo "[CI-CERT-PROVISION] TLS:    artifacts/registry-certs-ci/registry.crt (CA-signed)" >&2
echo "[CI-CERT-PROVISION] config: artifacts/registry-runtime/${REGISTRY_CONTAINER}-config.yml (TLS)" >&2
echo "[CI-CERT-PROVISION] ════════════════════════════════════════════" >&2

# Emit env-var exports to stdout so caller can eval them
printf 'export CI_REGISTRY_CERTS_DIR=%s\n' "${CI_CERTS_OUTDIR}"
printf 'export CI_REGISTRY_CONFIG=%s\n' "${CI_REGISTRY_CONFIG}"
