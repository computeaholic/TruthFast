#!/usr/bin/env bash
set -euo pipefail

LEDGER_SEAL="/home/threadforge/threadforge/platform/deploy/infra/k3s/audit/AUDIT_LEDGER_SEAL.json"
if [ ! -f "$LEDGER_SEAL" ]; then
  echo "ERROR: ledger seal missing" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
LEDGER_SHA=$(jq -r '.ledger_sha256' "$LEDGER_SEAL")
LAST_CHAIN_HASH=$(jq -r '.last_chain_hash' "$LEDGER_SEAL")
ENTRY_COUNT=$(jq -r '.entry_count' "$LEDGER_SEAL")

jq -n \
  --arg timestamp "$(date --iso-8601=seconds)" \
  --arg ledger_sha256 "$LEDGER_SHA" \
  --arg last_chain_hash "$LAST_CHAIN_HASH" \
  --argjson entry_count "$ENTRY_COUNT" \
  '{timestamp:$timestamp,ledger_sha256:$ledger_sha256,last_chain_hash:$last_chain_hash,entry_count:$entry_count}'

exit 0
