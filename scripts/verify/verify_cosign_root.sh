#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

COSIGN_PUB="${HOME}/.threadforge-signing/cosign.pub"
EXPECTED_SHA_FILE="artifacts/proof/cosign_root.sha256"

if [[ ! -f "$COSIGN_PUB" ]]; then
  echo "[FAIL] COSIGN_ROOT_MISSING: $COSIGN_PUB"
  exit 2
fi

mkdir -p "$(dirname "$EXPECTED_SHA_FILE")"
ACTUAL_SHA="$(sha256sum "$COSIGN_PUB" | awk '{print $1}')"

if [[ ! -f "$EXPECTED_SHA_FILE" ]]; then
  echo "[FAIL] COSIGN_ROOT_NOT_PINNED: $EXPECTED_SHA_FILE"
  exit 2
fi

EXPECTED_SHA="$(tr -d '[:space:]' < "$EXPECTED_SHA_FILE")"

if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  echo "[FAIL] COSIGN_ROOT_MISMATCH"
  echo "expected=$EXPECTED_SHA"
  echo "actual=$ACTUAL_SHA"
  exit 2
fi

echo "[PASS] COSIGN_ROOT_VERIFIED"
