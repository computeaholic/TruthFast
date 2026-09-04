#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

AUDIT_LOG_PATH="${THREADFORGE_AUDIT_LOG_PATH:-$REPO_ROOT/artifacts/audit/audit.log}"
ARTIFACT_PATH="$REPO_ROOT/artifacts/audit_logging_validation.json"
CHAIN_META="$REPO_ROOT/artifacts/audit/audit.chain.json"
GENESIS_SIG="$REPO_ROOT/artifacts/audit/audit.genesis.sig"
COSIGN_BIN="${COSIGN_BIN:-$HOME/.local/bin/cosign}"
SIGNING_KEY_REGISTRY="${THREADFORGE_SIGNING_KEY_REGISTRY:-$REPO_ROOT/artifacts/audit/signing_key_registry.json}"
SIGNING_KEY_REGISTRY_SIG="${THREADFORGE_SIGNING_KEY_REGISTRY_SIG:-$REPO_ROOT/artifacts/audit/signing_key_registry.sig}"
LEGACY_SIGNING_KEY_ID="${THREADFORGE_LEGACY_SIGNING_KEY_ID:-cosign_v1}"

# Security: reject THREADFORGE_AUDIT_LOG_PATH overrides that point outside the
# canonical proof artifact tree.  An attacker with write access to arbitrary
# file system paths could otherwise forge a passing audit log and set the env
# var to point at it.
if [ -n "${THREADFORGE_AUDIT_LOG_PATH:-}" ]; then
  CANONICAL_AUDIT_BASE="$REPO_ROOT/artifacts"
  resolved_path="$(realpath -m "$THREADFORGE_AUDIT_LOG_PATH" 2>/dev/null || echo "$THREADFORGE_AUDIT_LOG_PATH")"
  canonical_base_resolved="$(realpath -m "$CANONICAL_AUDIT_BASE" 2>/dev/null || echo "$CANONICAL_AUDIT_BASE")"
  if [[ "$resolved_path" != "$canonical_base_resolved"* ]]; then
    echo "[FAIL] AUDIT_INTEGRITY: THREADFORGE_AUDIT_LOG_PATH points outside artifacts/ tree: $THREADFORGE_AUDIT_LOG_PATH"
    exit 2
  fi
fi

ensure_cluster_readable || exit $?

if [ ! -f "$AUDIT_LOG_PATH" ]; then
  echo "[FAIL] audit log missing: $AUDIT_LOG_PATH"
  exit 2
fi

# ── Phase 1: Hash chain + structural validation ────────────────────────────
export THREADFORGE_LEGACY_SIGNING_KEY_ID="$LEGACY_SIGNING_KEY_ID"
CHAIN_OUTPUT=$(python3 - "$AUDIT_LOG_PATH" "$ARTIFACT_PATH" <<'PY'
import hashlib
import json
import os
import pathlib
import sys

log_path = pathlib.Path(sys.argv[1])
artifact_path = pathlib.Path(sys.argv[2])
required = {
    "timestamp",
    "actor_spiffe_id",
    "actor_role",
    "namespace",
    "action",
    "resource",
    "result",
    "reason",
}

require_breakglass_entry = os.getenv("THREADFORGE_REQUIRE_BREAKGLASS_ENTRY", "false").strip().lower() == "true"
legacy_signing_key_id = os.getenv("THREADFORGE_LEGACY_SIGNING_KEY_ID", "cosign_v1").strip() or "cosign_v1"

lines = [line.strip() for line in log_path.read_text(encoding="utf-8").splitlines() if line.strip()]
if not lines:
    raise SystemExit("[FAIL] audit log exists but is empty")

allow_seen = False
deny_seen = False
breakglass_seen = False
signing_key_ids_seen: set[str] = set()

# SHA256 hash chain: each entry must include a prev_hash field (or be the first
# entry with prev_hash == "0" * 64), and the chain must be internally consistent.
prev_hash = "0" * 64
hash_chain_valid = True
hash_chain_error = None
genesis_hash = ""

for idx, line in enumerate(lines, start=1):
    try:
        event = json.loads(line)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"[FAIL] audit log line {idx} is not valid JSON: {exc}")
    missing = sorted(k for k in required if not str(event.get(k, "")).strip())
    if missing:
        raise SystemExit(f"[FAIL] audit log line {idx} missing fields: {', '.join(missing)}")

    # Backward-compatibility: legacy events may not yet have breakglass field.
    # Treat missing as false for semantic checks, but do not inject it into the
    # hash-chain computation for existing entries.
    has_breakglass = "breakglass" in event
    if not has_breakglass:
      event["breakglass"] = False
    if not isinstance(event.get("breakglass"), bool):
        raise SystemExit(f"[FAIL] audit log line {idx} field breakglass must be boolean")
    request_groups = event.get("request_groups", [])
    if request_groups in (None, ""):
      request_groups = []
    if isinstance(request_groups, str):
      request_groups = [g.strip() for g in request_groups.split(",") if g.strip()]
    if not isinstance(request_groups, list) or not all(isinstance(g, str) for g in request_groups):
      raise SystemExit(f"[FAIL] audit log line {idx} field request_groups must be list[str] or CSV string")
    if "threadforge-breakglass" in request_groups and event["breakglass"] is not True:
      raise SystemExit(
        f"[FAIL] AUDIT_INTEGRITY: line {idx} has request_groups including threadforge-breakglass but breakglass != true"
      )
    if event["breakglass"]:
        breakglass_seen = True

    signing_key_id = str(event.get("signing_key_id", "")).strip()
    if not signing_key_id:
      signing_key_id = legacy_signing_key_id
    signing_key_ids_seen.add(signing_key_id)

    result = str(event.get("result", "")).upper()
    if result == "ALLOW":
        allow_seen = True
    elif result == "DENY":
        deny_seen = True

    if idx == 1:
        declared_prev = str(event.get("prev_hash", "0" * 64)).strip() or "0" * 64
        if declared_prev != "0" * 64:
            hash_chain_valid = False
            hash_chain_error = (
                f"line {idx}: genesis prev_hash must be {'0' * 64!r} or absent, got {declared_prev!r}"
            )
            break
    else:
        if "prev_hash" not in event:
            hash_chain_valid = False
            hash_chain_error = (
                f"line {idx}: prev_hash field is mandatory after entry 0 but is missing"
            )
            break
        declared_prev = str(event["prev_hash"])
        if declared_prev != prev_hash:
            hash_chain_valid = False
            hash_chain_error = (
                f"line {idx}: prev_hash mismatch — expected {prev_hash!r}, got {declared_prev!r}"
            )
            break
    entry_for_hash = {k: v for k, v in event.items() if k != "prev_hash"}
    if not has_breakglass:
      entry_for_hash.pop("breakglass", None)
    canonical = json.dumps(entry_for_hash, sort_keys=True, separators=(",", ":"))
    current_hash = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    if idx == 1:
        genesis_hash = current_hash
    prev_hash = current_hash

if not allow_seen:
    raise SystemExit("[FAIL] audit log missing ALLOW event")
if not deny_seen:
    raise SystemExit("[FAIL] audit log missing DENY event")
if not hash_chain_valid:
    raise SystemExit(f"[FAIL] AUDIT_INTEGRITY: hash chain broken — {hash_chain_error}")
if require_breakglass_entry and not breakglass_seen:
  raise SystemExit("[FAIL] AUDIT_INTEGRITY: break-glass audit expected but no breakglass=true event found")

artifact_path.parent.mkdir(parents=True, exist_ok=True)
artifact_path.write_text(
    json.dumps(
        {
            "status": "PASS",
            "audit_log": str(log_path),
            "entries": len(lines),
            "allow_seen": allow_seen,
            "deny_seen": deny_seen,
            "breakglass_seen": breakglass_seen,
            "signing_key_ids_seen": sorted(signing_key_ids_seen),
            "hash_chain_validated": True,
            "hash_chain_mandatory": True,
            "genesis_hash": genesis_hash,
            "final_hash": prev_hash,
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
import sys as _sys
# Emit genesis hash to stdout so shell can capture it for signature verification
print(f"GENESIS_HASH={genesis_hash}")
print("[PASS] structured audit logging validated")
PY
)

echo "$CHAIN_OUTPUT" | grep -v "^GENESIS_HASH=" || true
COMPUTED_GENESIS=$(echo "$CHAIN_OUTPUT" | grep "^GENESIS_HASH=" | cut -d= -f2 || true)

# ── Phase 2: Signing key trust verification + deterministic rotation chain ───
# Verifies all signing_key_id values in log are trusted, verifies genesis
# signature with original key, and verifies each key rotation edge vN->vN+1.
ROTATION_OUTPUT=$(python3 - "$REPO_ROOT" "$AUDIT_LOG_PATH" "$SIGNING_KEY_REGISTRY" "$SIGNING_KEY_REGISTRY_SIG" "$GENESIS_SIG" "$COMPUTED_GENESIS" "$COSIGN_BIN" "$LEGACY_SIGNING_KEY_ID" <<'PY'
import json
import os
import pathlib
import subprocess
import sys
import tempfile

repo_root = pathlib.Path(sys.argv[1]).resolve()
log_path = pathlib.Path(sys.argv[2]).resolve()
registry_arg = sys.argv[3]
registry_sig_arg = sys.argv[4]
genesis_sig_path = pathlib.Path(sys.argv[5]).resolve()
computed_genesis = (sys.argv[6] or "").strip()
cosign_bin = sys.argv[7]
legacy_signing_key_id = (sys.argv[8] or "cosign_v1").strip() or "cosign_v1"

def fail(msg: str) -> None:
  raise SystemExit(f"[FAIL] AUDIT_INTEGRITY: {msg}")

def resolve_path(raw: str) -> pathlib.Path:
  expanded = os.path.expandvars(os.path.expanduser(raw.strip()))
  p = pathlib.Path(expanded)
  if not p.is_absolute():
    p = repo_root / p
  return p.resolve()

registry_path = resolve_path(registry_arg)
registry_sig_path = resolve_path(registry_sig_arg)
if not registry_path.exists():
  fail(f"signing key registry missing: {registry_path}")
if not registry_sig_path.exists():
  fail(f"signing key registry signature missing: {registry_sig_path}")

try:
  registry = json.loads(registry_path.read_text(encoding="utf-8"))
except json.JSONDecodeError as exc:
  fail(f"invalid signing key registry JSON: {exc}")

keys = registry.get("keys")
if not isinstance(keys, dict) or not keys:
  fail("signing key registry has no keys")

genesis_key_id = str(registry.get("genesis_key_id", "")).strip()
active_key_id = str(registry.get("active_key_id", "")).strip()
if not genesis_key_id or genesis_key_id not in keys:
  fail("registry genesis_key_id is missing or untrusted")
if not active_key_id or active_key_id not in keys:
  fail("registry active_key_id is missing or untrusted")

genesis_pub = resolve_path(str(keys[genesis_key_id]["public_key_path"]))
registry_sig_verify = subprocess.run(
  [
    cosign_bin,
    "verify-blob",
    "--key",
    str(genesis_pub),
    "--signature",
    str(registry_sig_path),
    str(registry_path),
  ],
  stdout=subprocess.PIPE,
  stderr=subprocess.PIPE,
  text=True,
  check=False,
)
if registry_sig_verify.returncode != 0:
  fail("signing key registry signature INVALID under registry genesis key")

for key_id, key_info in keys.items():
  if not isinstance(key_info, dict):
    fail(f"key entry {key_id!r} must be object")
  pub_path = resolve_path(str(key_info.get("public_key_path", "")))
  if not pub_path.exists():
    fail(f"public key for {key_id!r} not found: {pub_path}")

signing_key_ids_seen = set()
for idx, line in enumerate(log_path.read_text(encoding="utf-8").splitlines(), start=1):
  line = line.strip()
  if not line:
    continue
  try:
    event = json.loads(line)
  except json.JSONDecodeError as exc:
    fail(f"invalid JSON while reading signing_key_id at line {idx}: {exc}")
  key_id = str(event.get("signing_key_id", "")).strip() or legacy_signing_key_id
  signing_key_ids_seen.add(key_id)

untrusted = sorted([k for k in signing_key_ids_seen if k not in keys])
if untrusted:
  fail(f"untrusted signing key id(s) present in audit log: {', '.join(untrusted)}")

if not genesis_sig_path.exists():
  fail(f"genesis signature missing: {genesis_sig_path}")
if not computed_genesis:
  fail("computed genesis hash is empty")

with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as handle:
  handle.write(computed_genesis)
  blob_path = pathlib.Path(handle.name)
try:
  proc = subprocess.run(
    [
      cosign_bin,
      "verify-blob",
      "--key",
      str(genesis_pub),
      "--signature",
      str(genesis_sig_path),
      str(blob_path),
    ],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    check=False,
  )
finally:
  try:
    blob_path.unlink(missing_ok=True)
  except Exception:
    pass

if proc.returncode != 0:
  fail("genesis hash cosign signature INVALID under registry genesis key")

rotations = registry.get("rotations", [])
if not isinstance(rotations, list):
  fail("registry rotations must be an array")

cursor = genesis_key_id
for idx, rotation in enumerate(rotations, start=1):
  if not isinstance(rotation, dict):
    fail(f"rotation {idx} must be object")
  from_key = str(rotation.get("from", "")).strip()
  to_key = str(rotation.get("to", "")).strip()
  sig_path_raw = str(rotation.get("signature_path", "")).strip()
  if not from_key or not to_key or not sig_path_raw:
    fail(f"rotation {idx} missing required fields from/to/signature_path")
  if from_key != cursor:
    fail(f"rotation chain broken at step {idx}: expected from={cursor}, got from={from_key}")
  if from_key not in keys or to_key not in keys:
    fail(f"rotation {idx} references untrusted key id")

  sig_path = resolve_path(sig_path_raw)
  if not sig_path.exists():
    fail(f"rotation signature missing at step {idx}: {sig_path}")

  from_pub = resolve_path(str(keys[from_key]["public_key_path"]))
  to_pub = resolve_path(str(keys[to_key]["public_key_path"]))
  proc = subprocess.run(
    [
      cosign_bin,
      "verify-blob",
      "--key",
      str(from_pub),
      "--signature",
      str(sig_path),
      str(to_pub),
    ],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    check=False,
  )
  if proc.returncode != 0:
    fail(f"rotation signature invalid at step {idx}: {from_key}->{to_key}")
  cursor = to_key

if rotations and active_key_id != cursor:
  fail(f"active_key_id mismatch: expected {cursor} from rotation chain, got {active_key_id}")

print(f"[PASS] audit genesis hash cosign signature verified with genesis key {genesis_key_id}")
print(f"[PASS] signing key registry signature verified ({registry_sig_path})")
print(f"[PASS] signing key trust registry validated ({len(keys)} trusted key(s))")
if rotations:
  print(f"[PASS] signing key rotation chain validated ({len(rotations)} rotation step(s))")
else:
  print("[PASS] signing key rotation chain validated (no rotations configured)")
PY
)
echo "$ROTATION_OUTPUT"

# ── Phase 3: ConfigMap anchor cross-check (defense-in-depth) ──────────────────
if kubectl cluster-info >/dev/null 2>&1; then
  CM_LATEST=$(kubectl -n kyverno get configmap threadforge-audit-chain-anchor \
    -o jsonpath='{.data.latest}' 2>/dev/null || true)
  if [ -n "$CM_LATEST" ] && [ -n "$COMPUTED_GENESIS" ]; then
    CM_GENESIS=$(kubectl -n kyverno get configmap threadforge-audit-chain-anchor \
      -o jsonpath='{.data.genesis}' 2>/dev/null || true)
    if [ -n "$CM_GENESIS" ] && [ "$CM_GENESIS" != "$COMPUTED_GENESIS" ]; then
      echo "[FAIL] AUDIT_INTEGRITY: computed genesis hash ($COMPUTED_GENESIS) does not match ConfigMap anchor ($CM_GENESIS) — log may have been replaced"
      exit 2
    fi
    echo "[PASS] audit chain ConfigMap anchor cross-check OK"
  fi
fi

exit 0
