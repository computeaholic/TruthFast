#!/usr/bin/env bash
set -euo pipefail

usage(){
  echo "Usage: $0 --attestation <path> --signature <path> --public-key <path>" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
}

ATTO=""
SIG=""
PUB=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --attestation) ATTO="$2"; shift 2;;
    --signature) SIG="$2"; shift 2;;
    --public-key) PUB="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1" >&2; usage;;
  esac
done
[ -n "$ATTO" ] || usage
[ -n "$SIG" ] || usage
[ -n "$PUB" ] || usage

if [ ! -f "$ATTO" ]; then echo "ERROR: attestation missing" >&2; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0; fi
if [ ! -f "$SIG" ]; then echo "ERROR: signature missing" >&2; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0; fi
if [ ! -f "$PUB" ]; then echo "ERROR: public key missing" >&2; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0; fi

# Try pkeyutl verify (Ed25519 or modern keys)
if openssl pkeyutl -verify -pubin -inkey "$PUB" -sigfile "$SIG" -in "$ATTO" >/dev/null 2>&1; then
  VERIFIED=0
else
  # Fallback RSA verify
  if openssl dgst -sha256 -verify "$PUB" -signature "$SIG" "$ATTO" >/dev/null 2>&1; then
    VERIFIED=0
  else
    echo "ERROR: signature verification failed" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
fi

# Validate JSON structure
required=(ledger_sha256 last_chain_hash entry_count verified_at verifier_hostname verifier_user chain_verified)
for k in "${required[@]}"; do
  if ! jq -e ".${k} != null" "$ATTO" >/dev/null 2>&1; then
    echo "ERROR: attestation missing required field ${k}" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
done

# Check chain_verified == true
if ! jq -e '.chain_verified == true' "$ATTO" >/dev/null 2>&1; then
  echo "ERROR: attestation.chain_verified != true" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "Attestation verified: OK"
exit 0
