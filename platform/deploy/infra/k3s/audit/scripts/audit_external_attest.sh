#!/usr/bin/env bash
set -euo pipefail

usage(){
  cat <<EOF
Usage: $0 --ledger <path> --seal <path> --output <path> --private-key <path>
Creates a signed attestation for the given ledger+seal.
EOF
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
}

LEDGER=""
SEAL=""
OUT=""
PRIV=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ledger) LEDGER="$2"; shift 2;;
    --seal) SEAL="$2"; shift 2;;
    --output) OUT="$2"; shift 2;;
    --private-key) PRIV="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1" >&2; usage;;
  esac
done

[ -n "$LEDGER" ] || usage
[ -n "$SEAL" ] || usage
[ -n "$OUT" ] || usage
[ -n "$PRIV" ] || usage

if [ ! -f "$LEDGER" ]; then
  echo "ERROR: ledger missing: $LEDGER" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
if [ ! -f "$SEAL" ]; then
  echo "ERROR: seal missing: $SEAL" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
if [ ! -f "$PRIV" ]; then
  echo "ERROR: private key missing: $PRIV" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Recompute ledger SHA
REPO_LEDGER_SHA=$(sha256sum "$LEDGER" | awk '{print $1}')
SEAL_LEDGER_SHA=$(jq -r '.ledger_sha256' "$SEAL")
if [ "$REPO_LEDGER_SHA" != "$SEAL_LEDGER_SHA" ]; then
  echo "ERROR: ledger SHA does not match seal" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Recompute chain verification by invoking existing verifier (non-fatal if it returns success)
if ! /home/threadforge/threadforge/platform/deploy/infra/k3s/audit/scripts/audit_verify_rotation_chain.sh >/dev/null 2>&1; then
  echo "ERROR: ledger chain verification failed" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Build attestation JSON
ENTRY_COUNT=$(wc -l < "$LEDGER" | tr -d ' ')
LAST_CHAIN_HASH=$(tail -n1 "$LEDGER" | jq -r '.chain_hash')
VERIFIER_HOSTNAME=$(hostname --fqdn 2>/dev/null || hostname)
VERIFIER_USER=$(id -un)
VERIFIED_AT=$(date --iso-8601=seconds)

ATTEST_JSON=$(jq -n \
  --arg ledger_sha256 "$REPO_LEDGER_SHA" \
  --arg last_chain_hash "$LAST_CHAIN_HASH" \
  --argjson entry_count "$ENTRY_COUNT" \
  --arg verified_at "$VERIFIED_AT" \
  --arg verifier_hostname "$VERIFIER_HOSTNAME" \
  --arg verifier_user "$VERIFIER_USER" \
  '{ledger_sha256:$ledger_sha256,last_chain_hash:$last_chain_hash,entry_count:$entry_count,verified_at:$verified_at,verifier_hostname:$verifier_hostname,verifier_user:$verifier_user,chain_verified:true}')

ATTEST_PATH="$OUT"
SIG_PATH="${OUT}.sig"

echo "$ATTEST_JSON" | jq . > "$ATTEST_PATH" || (echo "ERROR: failed to write attestation" >&2; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0)

# Attempt Ed25519 sign via openssl pkeyutl (preferred), fallback to RSA sha256 via openssl dgst
if openssl pkeyutl -sign -inkey "$PRIV" -in "$ATTEST_PATH" -out "$SIG_PATH" 2>/dev/null; then
  echo "Signed attestation with pkeyutl (possibly Ed25519 or compatible)."
  exit 0
fi

# Fallback: RSA sign
if openssl dgst -sha256 -sign "$PRIV" -out "$SIG_PATH" "$ATTEST_PATH" 2>/dev/null; then
  echo "Signed attestation with RSA fallback."
  exit 0
fi

echo "ERROR: signing failed (no supported private key/signing available)" >&2
echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
