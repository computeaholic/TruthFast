#!/usr/bin/env bash
# ensure_cosign_keys.sh — Bootstrap cosign signing key pair if not present.
#
# On a clean machine the cosign key pair may not exist. This script generates a
# key pair once and stores it under $HOME/.threadforge-signing/. Subsequent
# invocations are no-ops.
#
# Key design decisions:
#   - Password is empty string (stored in cosign.password for sign_images.sh).
#   - Path respects COSIGN_KEY_DIR override or defaults to $HOME/.threadforge-signing.
#   - Non-interactive: safe to call from bootstrap / CI pipelines.
#   - Idempotent: skips generation if key files already exist.
#
# Exit codes:
#   0  — key pair present (created or pre-existing)
#   2  — cosign tool missing or key generation failed
set -euo pipefail

SIGNING_DIR="${COSIGN_KEY_DIR:-${HOME}/.threadforge-signing}"

export COSIGN_YES="${COSIGN_YES:-true}"

COSIGN_KEY="${SIGNING_DIR}/cosign.key"
COSIGN_PUB="${SIGNING_DIR}/cosign.pub"
COSIGN_PASS="${SIGNING_DIR}/cosign.password"

if [ -f "$COSIGN_KEY" ] && [ -f "$COSIGN_PUB" ]; then
  echo "[cosign] key pair already present at ${SIGNING_DIR}"
  # Ensure password file exists even if it was manually removed
  if [ ! -f "$COSIGN_PASS" ]; then
    printf '' > "$COSIGN_PASS"
    chmod 600 "$COSIGN_PASS"
    echo "[cosign] restored missing password file"
  fi
  exit 0
fi

if ! command -v cosign >/dev/null 2>&1; then
  echo "[FAIL] cosign not found in PATH — cannot generate signing keys"
  echo "       Install cosign: https://docs.sigstore.dev/cosign/system_config/installation/"
  exit 2
fi

echo "[cosign] generating new key pair at ${SIGNING_DIR}"
mkdir -p "${SIGNING_DIR}"
chmod 700 "${SIGNING_DIR}"

# Generate key pair non-interactively with an empty password.
# COSIGN_PASSWORD="" suppresses the interactive passphrase prompt.
(
  cd "${SIGNING_DIR}"
  COSIGN_PASSWORD="" cosign generate-key-pair >/dev/null 2>&1
)

# Write the password file (empty string — required by sign_images.sh).
printf '' > "${COSIGN_PASS}"

# Tighten permissions.
chmod 600 "${COSIGN_KEY}" "${COSIGN_PASS}"
chmod 644 "${COSIGN_PUB}"

echo "[cosign] key pair generated:"
echo "         key:      ${COSIGN_KEY}"
echo "         pubkey:   ${COSIGN_PUB}"
echo "         password: ${COSIGN_PASS} (empty passphrase)"
