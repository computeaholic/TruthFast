#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIGNING_DIR="${COSIGN_KEY_DIR:-$HOME/.threadforge-signing}"
REGISTRY_PATH="${THREADFORGE_SIGNING_KEY_REGISTRY:-$REPO_ROOT/artifacts/audit/signing_key_registry.json}"
REGISTRY_SIG_PATH="${THREADFORGE_SIGNING_KEY_REGISTRY_SIG:-$REPO_ROOT/artifacts/audit/signing_key_registry.sig}"
COSIGN_BIN="${COSIGN_BIN:-$HOME/.local/bin/cosign}"
PASSWORD_FILE="${COSIGN_PASSWORD_FILE:-$SIGNING_DIR/cosign.password}"

if [ ! -f "$REGISTRY_PATH" ]; then
  echo "[FAIL] signing key registry missing: $REGISTRY_PATH"
  exit 2
fi

if [ ! -f "$PASSWORD_FILE" ]; then
  printf '' > "$PASSWORD_FILE"
  chmod 600 "$PASSWORD_FILE"
fi

GENESIS_KEY_PATH="$(python3 - "$REGISTRY_PATH" <<'PY'
import json
import os
import pathlib
import sys

registry_path = pathlib.Path(sys.argv[1]).resolve()
reg = json.loads(registry_path.read_text(encoding="utf-8"))
genesis = str(reg.get("genesis_key_id", "")).strip()
keys = reg.get("keys", {})
if not genesis or genesis not in keys:
    raise SystemExit(2)
raw = str(keys[genesis].get("private_key_path", "")).strip()
if not raw:
    raise SystemExit(3)
print(str(pathlib.Path(os.path.expanduser(os.path.expandvars(raw)))))
PY
)"

if [ -z "$GENESIS_KEY_PATH" ] || [ ! -f "$GENESIS_KEY_PATH" ]; then
  echo "[FAIL] registry genesis private key missing: $GENESIS_KEY_PATH"
  exit 2
fi

mkdir -p "$(dirname "$REGISTRY_SIG_PATH")"
COSIGN_PASSWORD="$(cat "$PASSWORD_FILE")" "$COSIGN_BIN" sign-blob \
  --key "$GENESIS_KEY_PATH" \
  --yes \
  --output-signature "$REGISTRY_SIG_PATH" \
  "$REGISTRY_PATH" >/dev/null 2>&1

echo "[PASS] SIGNING_KEY_REGISTRY_SIGNED"
echo "[info] registry: $REGISTRY_PATH"
echo "[info] signature: $REGISTRY_SIG_PATH"
