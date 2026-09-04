#!/usr/bin/env bash
set -euo pipefail

THREADFORGE_REGISTRY="${THREADFORGE_REGISTRY:-registry.threadforge.local:30500}"
THREADFORGE_REGISTRY_USER="${THREADFORGE_REGISTRY_USER:-threadforge}"
THREADFORGE_REGISTRY_PASSWORD="${THREADFORGE_REGISTRY_PASSWORD:-threadforge-dev-password}"
ISTIO_TAG="${ISTIO_TAG:-1.29.0}"
SRC_BASE="${ISTIO_SRC_BASE:-${THREADFORGE_REGISTRY}/mirror/docker.io/istio}"
DST_BASE="${THREADFORGE_REGISTRY}/istio"
ISTIO_PILOT_DIGEST="${ISTIO_PILOT_DIGEST:-32515653577393f5e6375ccc1350a0cf0aabdd733f8fe9265bb51003a10be26f}"
ISTIO_PROXYV2_DIGEST="${ISTIO_PROXYV2_DIGEST:-2f78ddd13cbf6f600c8bebb9f05b21f9b14e047ec5f8c88ef9f50abc8e14466b}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIGNER_SCRIPT="$REPO_ROOT/scripts/supply_chain/sign_images.sh"
REGISTRY_CREDS="${THREADFORGE_REGISTRY_USER}:${THREADFORGE_REGISTRY_PASSWORD}"
REGISTRY_CA_CERT_PATH="${REGISTRY_CA_CERT_PATH:-$REPO_ROOT/certs/threadforge-ingress-ca.crt}"
REGISTRY_CERT_DIR=""

if ! command -v skopeo >/dev/null 2>&1; then
  echo "[FAIL] skopeo is required"
  exit 10
fi

if [[ ! -f "$REGISTRY_CA_CERT_PATH" ]]; then
  echo "[FAIL] registry CA cert missing: $REGISTRY_CA_CERT_PATH"
  exit 2
fi

REGISTRY_CERT_DIR="$(mktemp -d)"
cleanup_registry_cert_dir() {
  rm -rf "$REGISTRY_CERT_DIR"
}
trap cleanup_registry_cert_dir EXIT
cp "$REGISTRY_CA_CERT_PATH" "$REGISTRY_CERT_DIR/ca.crt"

registry_re="^${THREADFORGE_REGISTRY//./\\.}/"

if [[ ! "$SRC_BASE" =~ $registry_re ]]; then
  echo "[FAIL] SRC_BASE must be internal registry only: $SRC_BASE"
  exit 2
fi

mirror_one() {
  local name="$1"
  local digest="$2"
  local src="${SRC_BASE}/${name}@sha256:${digest}"
  local dst="${DST_BASE}/${name}@sha256:${digest}"
  local dst_tag="${DST_BASE}/${name}:${ISTIO_TAG}"

  if skopeo inspect --tls-verify=true --cert-dir "$REGISTRY_CERT_DIR" --creds "${REGISTRY_CREDS}" "docker://${dst}" >/dev/null 2>&1; then
    echo "[ISTIO-IMAGES] Reusing existing internal image ${dst}"
  else
    if ! skopeo inspect --tls-verify=true --cert-dir "$REGISTRY_CERT_DIR" --creds "${REGISTRY_CREDS}" "docker://${src}" >/dev/null 2>&1; then
      echo "[FAIL] required internal Istio source image missing: ${src}"
      echo "[FAIL] and destination image not present: ${dst}"
      exit 2
    fi

    echo "[ISTIO-IMAGES] Mirroring ${src} -> ${dst}"
    skopeo copy --src-creds "${REGISTRY_CREDS}" --dest-creds "${REGISTRY_CREDS}" --src-tls-verify=true --dest-tls-verify=true --src-cert-dir "$REGISTRY_CERT_DIR" --dest-cert-dir "$REGISTRY_CERT_DIR" "docker://${src}" "docker://${dst}"
  fi

  skopeo copy --src-creds "${REGISTRY_CREDS}" --dest-creds "${REGISTRY_CREDS}" --src-tls-verify=true --dest-tls-verify=true --src-cert-dir "$REGISTRY_CERT_DIR" --dest-cert-dir "$REGISTRY_CERT_DIR" "docker://${dst}" "docker://${dst_tag}"

  if [ -x "$SIGNER_SCRIPT" ]; then
    "$SIGNER_SCRIPT" --mode sign --image "$dst"
  else
    echo "[FAIL] pre-deploy signing script missing or not executable: $SIGNER_SCRIPT"
    exit 10
  fi

  "$SIGNER_SCRIPT" --mode verify --image "$dst"
}

mirror_one pilot "${ISTIO_PILOT_DIGEST}"
mirror_one proxyv2 "${ISTIO_PROXYV2_DIGEST}"

echo "[ISTIO-IMAGES] Mirror complete"
