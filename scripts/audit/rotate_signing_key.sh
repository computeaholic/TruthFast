#!/usr/bin/env bash
set -euo pipefail

# THREADFORGE deterministic audit signing-key rotation
#
# Flow:
# 1) Generate new cosign keypair (cosign_vN)
# 2) Sign new public key with previous key
# 3) Persist rotation signature and update trusted key registry

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIGNING_DIR="${COSIGN_KEY_DIR:-$HOME/.threadforge-signing}"
REGISTRY_PATH="${THREADFORGE_SIGNING_KEY_REGISTRY:-$REPO_ROOT/artifacts/audit/signing_key_registry.json}"
REGISTRY_SIG_PATH="${THREADFORGE_SIGNING_KEY_REGISTRY_SIG:-$REPO_ROOT/artifacts/audit/signing_key_registry.sig}"
COSIGN_BIN="${COSIGN_BIN:-$HOME/.local/bin/cosign}"
PASSWORD_FILE="${COSIGN_PASSWORD_FILE:-$SIGNING_DIR/cosign.password}"

mkdir -p "$SIGNING_DIR" "$REPO_ROOT/artifacts/audit"

if [ ! -f "$PASSWORD_FILE" ]; then
  printf '' > "$PASSWORD_FILE"
  chmod 600 "$PASSWORD_FILE"
fi

if [ ! -f "$REGISTRY_PATH" ]; then
  # Seed registry from legacy key material if present.
  if [ ! -f "$SIGNING_DIR/cosign_v1.key" ] && [ -f "$SIGNING_DIR/cosign.key" ]; then
    cp "$SIGNING_DIR/cosign.key" "$SIGNING_DIR/cosign_v1.key"
  fi
  if [ ! -f "$SIGNING_DIR/cosign_v1.pub" ] && [ -f "$SIGNING_DIR/cosign.pub" ]; then
    cp "$SIGNING_DIR/cosign.pub" "$SIGNING_DIR/cosign_v1.pub"
  fi
  if [ ! -f "$SIGNING_DIR/cosign_v1.key" ] || [ ! -f "$SIGNING_DIR/cosign_v1.pub" ]; then
    echo "[FAIL] cannot seed v1 keypair: missing $SIGNING_DIR/cosign_v1.{key,pub} or legacy cosign.{key,pub}"
    exit 2
  fi

  cat > "$REGISTRY_PATH" <<JSON
{
  "version": 1,
  "genesis_key_id": "cosign_v1",
  "active_key_id": "cosign_v1",
  "keys": {
    "cosign_v1": {
      "public_key_path": "~/.threadforge-signing/cosign_v1.pub",
      "private_key_path": "~/.threadforge-signing/cosign_v1.key"
    }
  },
  "rotations": []
}
JSON
  echo "[rotate] initialized signing key registry at $REGISTRY_PATH"
fi

ACTIVE_KEY_ID="$(python3 - "$REGISTRY_PATH" <<'PY'
import json, pathlib, sys
reg = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
print(reg.get('active_key_id', '').strip())
PY
)"

if [ -z "$ACTIVE_KEY_ID" ]; then
  echo "[FAIL] active_key_id missing from registry"
  exit 2
fi

NEXT_KEY_ID="${THREADFORGE_NEXT_KEY_ID:-}"
if [ -z "$NEXT_KEY_ID" ]; then
  NEXT_KEY_ID="$(python3 - "$ACTIVE_KEY_ID" <<'PY'
import re, sys
active = sys.argv[1]
m = re.fullmatch(r'cosign_v(\d+)', active)
if not m:
    raise SystemExit(2)
print(f"cosign_v{int(m.group(1)) + 1}")
PY
)"
fi

if [ "$NEXT_KEY_ID" = "$ACTIVE_KEY_ID" ]; then
  echo "[FAIL] NEXT_KEY_ID equals active key id: $ACTIVE_KEY_ID"
  exit 2
fi

OLD_KEY_PATH="$SIGNING_DIR/${ACTIVE_KEY_ID}.key"
OLD_PUB_PATH="$SIGNING_DIR/${ACTIVE_KEY_ID}.pub"
NEW_KEY_PATH="$SIGNING_DIR/${NEXT_KEY_ID}.key"
NEW_PUB_PATH="$SIGNING_DIR/${NEXT_KEY_ID}.pub"

if [ ! -f "$OLD_KEY_PATH" ] || [ ! -f "$OLD_PUB_PATH" ]; then
  echo "[FAIL] active key material missing for $ACTIVE_KEY_ID"
  exit 2
fi

if [ -f "$NEW_KEY_PATH" ] || [ -f "$NEW_PUB_PATH" ]; then
  echo "[FAIL] target key id already exists: $NEXT_KEY_ID"
  exit 2
fi

echo "[rotate] generating keypair: $NEXT_KEY_ID"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
(
  cd "$TMP_DIR"
  COSIGN_PASSWORD="$(cat "$PASSWORD_FILE")" "$COSIGN_BIN" generate-key-pair >/dev/null 2>&1
)
mv "$TMP_DIR/cosign.key" "$NEW_KEY_PATH"
mv "$TMP_DIR/cosign.pub" "$NEW_PUB_PATH"
chmod 600 "$NEW_KEY_PATH"
chmod 644 "$NEW_PUB_PATH"

echo "[rotate] signing new public key with previous key"
ROT_SIG="$REPO_ROOT/artifacts/audit/key_rotation_${ACTIVE_KEY_ID}_to_${NEXT_KEY_ID}.sig"
COSIGN_PASSWORD="$(cat "$PASSWORD_FILE")" "$COSIGN_BIN" sign-blob \
  --key "$OLD_KEY_PATH" \
  --yes \
  --output-signature "$ROT_SIG" \
  "$NEW_PUB_PATH" >/dev/null 2>&1

echo "[rotate] updating trusted signing key registry"
python3 - "$REGISTRY_PATH" "$NEXT_KEY_ID" "$ROT_SIG" <<'PY'
import datetime
import json
import pathlib
import sys

registry_path = pathlib.Path(sys.argv[1])
next_key_id = sys.argv[2]
sig_path = pathlib.Path(sys.argv[3]).resolve()

reg = json.loads(registry_path.read_text(encoding="utf-8"))
active = reg["active_key_id"]
keys = reg.setdefault("keys", {})
rotations = reg.setdefault("rotations", [])

if next_key_id in keys:
    raise SystemExit("new key id already present in registry")

keys[next_key_id] = {
    "public_key_path": f"~/.threadforge-signing/{next_key_id}.pub",
    "private_key_path": f"~/.threadforge-signing/{next_key_id}.key",
    "created_at": datetime.datetime.now(datetime.UTC).isoformat(),
}
rotations.append(
    {
        "from": active,
        "to": next_key_id,
        "signature_path": str(sig_path),
        "created_at": datetime.datetime.now(datetime.UTC).isoformat(),
    }
)
reg["active_key_id"] = next_key_id
registry_path.write_text(json.dumps(reg, indent=2) + "\n", encoding="utf-8")
PY

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
expanded = pathlib.Path(os.path.expanduser(os.path.expandvars(raw)))
print(str(expanded))
PY
)"
if [ -z "$GENESIS_KEY_PATH" ] || [ ! -f "$GENESIS_KEY_PATH" ]; then
  echo "[FAIL] unable to resolve registry genesis private key for signing"
  exit 2
fi

echo "[rotate] signing signing_key_registry.json with registry genesis key"
COSIGN_PASSWORD="$(cat "$PASSWORD_FILE")" "$COSIGN_BIN" sign-blob \
  --key "$GENESIS_KEY_PATH" \
  --yes \
  --output-signature "$REGISTRY_SIG_PATH" \
  "$REGISTRY_PATH" >/dev/null 2>&1

echo "$NEXT_KEY_ID" > "$SIGNING_DIR/active_key_id"

echo "[rotate] PASS"
echo "[rotate] old key:  $ACTIVE_KEY_ID"
echo "[rotate] new key:  $NEXT_KEY_ID"
echo "[rotate] registry: $REGISTRY_PATH"
echo "[rotate] registry signature: $REGISTRY_SIG_PATH"
echo "[rotate] signature artifact: $ROT_SIG"
