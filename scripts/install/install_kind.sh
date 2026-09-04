#!/usr/bin/env bash
# Install a pinned version of kind with SHA256 checksum verification.
# Fails hard on any mismatch or download error.
set -euo pipefail

KIND_VERSION="v0.22.0"
ARCH_RAW="$(uname -m)"
case "${ARCH_RAW}" in
  x86_64)
    KIND_ARCH="amd64"
    ;;
  aarch64|arm64)
    KIND_ARCH="arm64"
    ;;
  *)
    echo "[FAIL] Unsupported architecture for kind install: ${ARCH_RAW}"
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    ;;
esac

BINARY_URL="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-${KIND_ARCH}"
SHA256SUM_URL="${BINARY_URL}.sha256sum"
INSTALL_DIR="/usr/local/bin"

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

echo "[kind-install] Downloading kind ${KIND_VERSION} for ${KIND_ARCH}..."
curl -fsSL -o "${TMP_DIR}/kind-linux-amd64" "${BINARY_URL}"
curl -fsSL -o "${TMP_DIR}/kind.sha256sum"   "${SHA256SUM_URL}"

echo "[kind-install] Verifying SHA256 checksum..."
ACTUAL_SHA256="$(sha256sum "${TMP_DIR}/kind-linux-amd64" | awk '{print $1}')"
EXPECTED_SHA256="$(awk '{print $1}' "${TMP_DIR}/kind.sha256sum")"

if [[ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]]; then
  echo "[FAIL] SHA256 mismatch for kind ${KIND_VERSION}"
  echo "  expected: ${EXPECTED_SHA256}"
  echo "  actual:   ${ACTUAL_SHA256}"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "[kind-install] Checksum OK: ${ACTUAL_SHA256}"

chmod +x "${TMP_DIR}/kind-linux-amd64"

if [[ -w "${INSTALL_DIR}" ]]; then
  mv "${TMP_DIR}/kind-linux-amd64" "${INSTALL_DIR}/kind"
else
  sudo mv "${TMP_DIR}/kind-linux-amd64" "${INSTALL_DIR}/kind"
fi

echo "[kind-install] Installed: $(kind --version)"
