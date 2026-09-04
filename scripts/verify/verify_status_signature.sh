#!/usr/bin/env bash
set -euo pipefail

STATUS_FILE="${STATUS_FILE:-artifacts/proof/status.json}"
STATUS_SIG="${STATUS_SIG:-artifacts/proof/status.json.sig}"
COSIGN_PUB="${HOME}/.threadforge-signing/cosign.pub"

if [[ ! -f "$STATUS_FILE" ]]; then
  echo "[FAIL] STATUS_FILE_MISSING: $STATUS_FILE"
  exit 2
fi

if [[ ! -f "$STATUS_SIG" ]]; then
  echo "[FAIL] STATUS_SIGNATURE_MISSING: $STATUS_SIG"
  exit 2
fi

if [[ ! -f "$COSIGN_PUB" ]]; then
  echo "[FAIL] COSIGN_ROOT_MISSING: $COSIGN_PUB"
  exit 2
fi

cosign verify-blob \
  --key "$COSIGN_PUB" \
  --signature "$STATUS_SIG" \
  "$STATUS_FILE" >/dev/null

echo "[PASS] STATUS_SIGNATURE_VERIFIED"
