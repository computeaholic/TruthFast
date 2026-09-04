#!/usr/bin/env bash
# scripts/audit/rebuild_audit_chain.sh
# ─────────────────────────────────────────────────────────────────────────────
# THREADFORGE — Audit Log Chain Rebuild + Cosign Anchor
#
# Purpose: Migrate legacy audit.log (no prev_hash) to a fully chained log, then
#          anchor the final hash via cosign and store it in a ConfigMap.
#
# Usage:
#   bash scripts/audit/rebuild_audit_chain.sh [--dry-run] [--no-cosign] [--no-configmap]
#
# Options:
#   --dry-run       Compute and display new log but do not write or anchor
#   --no-cosign     Skip cosign signing of genesis hash (requires running cluster)
#   --no-configmap  Skip ConfigMap anchor (for offline use)
#
# Outputs:
#   artifacts/audit/audit.log           ← rebuilt with prev_hash chain
#   artifacts/audit/audit.chain.json    ← chain metadata + genesis hash + final hash
#   artifacts/audit/audit.genesis.sig   ← cosign signature of genesis block (if signed)
#
# Invariant: verify_audit_logging.sh PASS on rebuilt log.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUDIT_LOG="$REPO_ROOT/artifacts/audit/audit.log"
CHAIN_META="$REPO_ROOT/artifacts/audit/audit.chain.json"
GENESIS_SIG="$REPO_ROOT/artifacts/audit/audit.genesis.sig"
COSIGN_KEY="${COSIGN_KEY:-$HOME/.threadforge-signing/cosign.key}"
COSIGN_PASSWORD_FILE="${COSIGN_PASSWORD_FILE:-$HOME/.threadforge-signing/cosign.password}"
COSIGN_BIN="${COSIGN_BIN:-$HOME/.local/bin/cosign}"
LEGACY_SIGNING_KEY_ID="${THREADFORGE_LEGACY_SIGNING_KEY_ID:-cosign_v1}"

DRY_RUN=false
NO_COSIGN=false
NO_CONFIGMAP=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)     DRY_RUN=true ;;
    --no-cosign)   NO_COSIGN=true ;;
    --no-configmap) NO_CONFIGMAP=true ;;
  esac
done

echo "[audit-chain] Starting audit log chain rebuild"
echo "[audit-chain] Log: $AUDIT_LOG"
echo "[audit-chain] Dry run: $DRY_RUN"

if [ ! -f "$AUDIT_LOG" ]; then
  echo "[FAIL] audit log not found: $AUDIT_LOG"
  exit 2
fi

ENTRY_COUNT=$(wc -l < "$AUDIT_LOG" | tr -d ' ')
echo "[audit-chain] Entries in existing log: $ENTRY_COUNT"

# ─── Phase 1: Rebuild log with correct hash chain ────────────────────────────
REBUILT_LOG="$REPO_ROOT/artifacts/audit/audit.log.rebuilt"
CHAIN_RESULT=$(python3 - "$AUDIT_LOG" "$REBUILT_LOG" "$LEGACY_SIGNING_KEY_ID" << 'PY'
import hashlib
import json
import pathlib
import sys

src_path  = pathlib.Path(sys.argv[1])
dest_path = pathlib.Path(sys.argv[2])
legacy_signing_key_id = (sys.argv[3] or "cosign_v1").strip() or "cosign_v1"

REQUIRED = {
    "timestamp", "actor_spiffe_id", "actor_role",
    "namespace", "action", "resource", "result", "reason",
}

lines = [l.strip() for l in src_path.read_text(encoding="utf-8").splitlines() if l.strip()]
if not lines:
    print("ERROR: audit log is empty", file=sys.stderr)
    sys.exit(1)

genesis_sentinel = "0" * 64
prev_hash = genesis_sentinel
rebuilt = []
skipped = 0

for idx, line in enumerate(lines, start=1):
    try:
        event = json.loads(line)
    except json.JSONDecodeError as e:
        print(f"[audit-chain] WARNING: skipping unparseable line {idx}: {e}", file=sys.stderr)
        skipped += 1
        continue

    missing = sorted(k for k in REQUIRED if not str(event.get(k, "")).strip())
    if missing:
        print(f"[audit-chain] WARNING: skipping line {idx} missing fields: {', '.join(missing)}", file=sys.stderr)
        skipped += 1
        continue

    # Build entry without prev_hash; assign canonical prev_hash
    entry = {k: v for k, v in event.items() if k != "prev_hash"}
    if "breakglass" not in entry:
      entry["breakglass"] = False
    else:
      entry["breakglass"] = bool(entry["breakglass"])
    if "signing_key_id" not in entry or not str(entry["signing_key_id"]).strip():
      entry["signing_key_id"] = legacy_signing_key_id
    if idx == 1:
        entry["prev_hash"] = genesis_sentinel
    else:
        entry["prev_hash"] = prev_hash

    # Compute this entry's hash (without prev_hash) for the next entry
    without_prev = {k: v for k, v in entry.items() if k != "prev_hash"}
    canonical = json.dumps(without_prev, sort_keys=True, separators=(",", ":"))
    current_hash = hashlib.sha256(canonical.encode("utf-8")).hexdigest()

    rebuilt.append(json.dumps(entry, sort_keys=False, separators=(", ", ": ")))
    prev_hash = current_hash

dest_path.write_text("\n".join(rebuilt) + "\n", encoding="utf-8")

# Output chain metadata as JSON to stdout
meta = {
    "entries_total": len(lines),
    "entries_valid": len(rebuilt),
    "entries_skipped": skipped,
    "genesis_sentinel": genesis_sentinel,
    "genesis_hash": hashlib.sha256(
        json.dumps(
            {k: v for k, v in json.loads(rebuilt[0]).items() if k != "prev_hash"},
            sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
    ).hexdigest() if rebuilt else "",
    "final_hash": prev_hash,
}
import sys as _sys
print(json.dumps(meta))
PY
)

echo "[audit-chain] Chain computation result:"
echo "$CHAIN_RESULT" | python3 -m json.tool 2>/dev/null || echo "$CHAIN_RESULT"

GENESIS_HASH=$(echo "$CHAIN_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['genesis_hash'])" 2>/dev/null || echo "")
FINAL_HASH=$(echo "$CHAIN_RESULT"   | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['final_hash'])"   2>/dev/null || echo "")

if [ -z "$GENESIS_HASH" ] || [ -z "$FINAL_HASH" ]; then
  echo "[FAIL] Chain computation failed — genesis_hash or final_hash empty"
  exit 2
fi

echo "[audit-chain] Genesis hash: $GENESIS_HASH"
echo "[audit-chain] Final hash:   $FINAL_HASH"

if [ "$DRY_RUN" = "true" ]; then
  echo "[audit-chain] DRY RUN — not writing rebuilt log"
  exit 0
fi

# ─── Phase 2: Verify rebuilt log passes verify_audit_logging.sh ──────────────
echo "[audit-chain] Verifying rebuilt log..."
if THREADFORGE_AUDIT_LOG_PATH="$REBUILT_LOG" bash "$REPO_ROOT/scripts/verify/verify_audit_logging.sh" > /tmp/audit_verify_rebuilt.txt 2>&1; then
  echo "[audit-chain] Verification PASS on rebuilt log"
else
  cat /tmp/audit_verify_rebuilt.txt
  echo "[FAIL] rebuilt log fails verify_audit_logging.sh — aborting"
  rm -f "$REBUILT_LOG"
  exit 2
fi

# ─── Phase 3: Atomically replace log ─────────────────────────────────────────
cp "$AUDIT_LOG" "${AUDIT_LOG}.bak.$(date +%Y%m%dT%H%M%SZ)"
mv "$REBUILT_LOG" "$AUDIT_LOG"
echo "[audit-chain] Rebuilt log installed at $AUDIT_LOG"

# ─── Phase 4: Write chain metadata ───────────────────────────────────────────
python3 - << PY
import json, pathlib, datetime

meta = json.loads('''$CHAIN_RESULT''')
meta["rebuilt_at"] = datetime.datetime.now(datetime.UTC).isoformat()
meta["log_path"] = "$AUDIT_LOG"
pathlib.Path("$CHAIN_META").write_text(
    json.dumps(meta, indent=2) + "\n", encoding="utf-8"
)
print("[audit-chain] Chain metadata written to $CHAIN_META")
PY

# ─── Phase 5: Cosign anchor of genesis hash ──────────────────────────────────
if [ "$NO_COSIGN" = "false" ]; then
  if [ -f "$COSIGN_KEY" ]; then
    echo "[audit-chain] Signing genesis hash with cosign..."
    GENESIS_BLOB_FILE="$(mktemp)"
    echo -n "$GENESIS_HASH" > "$GENESIS_BLOB_FILE"
    COSIGN_PASSWORD="$(cat "$COSIGN_PASSWORD_FILE")" \
      "$COSIGN_BIN" sign-blob \
        --key "$COSIGN_KEY" \
        --yes \
        --output-signature "$GENESIS_SIG" \
        "$GENESIS_BLOB_FILE" 2>/dev/null
    rm -f "$GENESIS_BLOB_FILE"
    echo "[audit-chain] Genesis hash signed → $GENESIS_SIG"
  else
    echo "[audit-chain] WARN: cosign key not found at $COSIGN_KEY — skipping signature"
    NO_COSIGN=true
  fi
fi

# ─── Phase 6: ConfigMap anchor (append-only final hash) ──────────────────────
if [ "$NO_CONFIGMAP" = "false" ]; then
  if kubectl cluster-info >/dev/null 2>&1; then
    echo "[audit-chain] Anchoring final hash in Kubernetes ConfigMap..."
    ANCHOR_KEY="anchor-$(date +%Y%m%dT%H%M%SZ)"
    kubectl -n kyverno create configmap threadforge-audit-chain-anchor \
      --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null || true
    kubectl -n kyverno patch configmap threadforge-audit-chain-anchor \
      --type merge \
      -p "{\"data\":{\"${ANCHOR_KEY}\":\"${FINAL_HASH}\",\"latest\":\"${FINAL_HASH}\",\"genesis\":\"${GENESIS_HASH}\"}}" 2>&1
    echo "[audit-chain] Final hash anchored in ConfigMap threadforge-audit-chain-anchor/$ANCHOR_KEY"
  else
    echo "[audit-chain] WARN: cluster not reachable — skipping ConfigMap anchor"
  fi
fi

echo "[audit-chain] DONE"
echo "[audit-chain] ┌─ Summary ───────────────────────────────────────────────"
echo "[audit-chain] │ Log:          $AUDIT_LOG"
echo "[audit-chain] │ Genesis hash: $GENESIS_HASH"
echo "[audit-chain] │ Final hash:   $FINAL_HASH"
echo "[audit-chain] │ Cosign sig:   $([ -f "$GENESIS_SIG" ] && echo YES || echo NO)"
echo "[audit-chain] │ ConfigMap:    $([ "$NO_CONFIGMAP" = "false" ] && echo YES || echo NO)"
echo "[audit-chain] └─────────────────────────────────────────────────────────"
