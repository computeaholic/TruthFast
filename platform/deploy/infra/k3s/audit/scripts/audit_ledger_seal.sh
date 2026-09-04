#!/usr/bin/env bash
set -euo pipefail

LEDGER="/home/threadforge/threadforge/platform/deploy/infra/k3s/audit/AUDIT_ROTATION_LEDGER.jsonl"
SEAL_FILE="/home/threadforge/threadforge/platform/deploy/infra/k3s/audit/AUDIT_LEDGER_SEAL.json"

if [ ! -f "$LEDGER" ]; then
  echo "ERROR: ledger missing: $LEDGER" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

LEDGER_SHA=$(sha256sum "$LEDGER" | awk '{print $1}')
ENTRY_COUNT=$(wc -l < "$LEDGER" | tr -d ' ')
LAST_CHAIN_HASH=$(tail -n1 "$LEDGER" | jq -r '.chain_hash')

jq -n \
  --arg ledger_sha256 "$LEDGER_SHA" \
  --argjson entry_count "$ENTRY_COUNT" \
  --arg last_chain_hash "$LAST_CHAIN_HASH" \
  --arg generated_at "$(date --iso-8601=seconds)" \
  '{ledger_sha256:$ledger_sha256,entry_count:$entry_count,last_chain_hash:$last_chain_hash,generated_at:$generated_at}' \
  > "$SEAL_FILE"

chmod 0644 "$SEAL_FILE"

echo "WROTE $SEAL_FILE"
exit 0
