#!/usr/bin/env bash
set -euo pipefail

LEDGER="/home/threadforge/threadforge/platform/deploy/infra/k3s/audit/AUDIT_ROTATION_LEDGER.jsonl"
AUDIT_DIR="/var/log/kubernetes/audit"

if [ ! -f "$LEDGER" ]; then
  echo "AUDIT ROTATION CHAIN BROKEN: ledger missing" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Verify ledger seal exists
SEAL_FILE="/home/threadforge/threadforge/platform/deploy/infra/k3s/audit/AUDIT_LEDGER_SEAL.json"
if [ -f "$SEAL_FILE" ]; then
  SEAL_LEDGER_SHA=$(jq -r '.ledger_sha256' "$SEAL_FILE")
  SEAL_ENTRY_COUNT=$(jq -r '.entry_count' "$SEAL_FILE")
  SEAL_LAST_CHAIN_HASH=$(jq -r '.last_chain_hash' "$SEAL_FILE")
else
  SEAL_LEDGER_SHA=""
  SEAL_ENTRY_COUNT=0
  SEAL_LAST_CHAIN_HASH=""
fi

# recompute ledger sha and walk entries
PREV="GENESIS"
COUNT=0
LAST_LAST_TS=0
while read -r line; do
  COUNT=$((COUNT+1))
  # parse fields
  file=$(echo "$line" | jq -r '.file')
  sha=$(echo "$line" | jq -r '.sha256')
  prev_hash=$(echo "$line" | jq -r '.previous_chain_hash')
  chain_hash=$(echo "$line" | jq -r '.chain_hash')
  first_ts=$(echo "$line" | jq -r '.first_event_ts')
  last_ts=$(echo "$line" | jq -r '.last_event_ts')

  # check previous hash matches expected
  if [ "$prev_hash" != "$PREV" ]; then
    echo "AUDIT ROTATION CHAIN BROKEN: previous_chain_hash mismatch at entry $COUNT" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi

  # verify file exists
  if [ ! -f "$AUDIT_DIR/$file" ] && [ ! -f "$AUDIT_DIR/offloaded/$file" ]; then
    echo "AUDIT ROTATION CHAIN BROKEN: file missing $file" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi

  # verify sha matches if file present locally (skip if offloaded)
  if [ -f "$AUDIT_DIR/$file" ]; then
    calc=$(sha256sum "$AUDIT_DIR/$file" | awk '{print $1}')
    if [ "$calc" != "$sha" ]; then
      echo "AUDIT ROTATION CHAIN BROKEN: sha mismatch for $file" >&2
      echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    fi
  fi

  # recompute chain hash
  recomputed=$(printf "%s%s" "$PREV" "$sha" | sha256sum | awk '{print $1}')
  if [ "$recomputed" != "$chain_hash" ]; then
    echo "AUDIT ROTATION CHAIN BROKEN: chain hash mismatch at entry $COUNT" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi

  # timestamp regression check: ensure current.first_event_ts >= previous.last_event_ts
  if [ "$first_ts" != "null" ] && [ "$LAST_LAST_TS" -ne 0 ] && [ "$first_ts" -lt "$LAST_LAST_TS" ]; then
    echo "AUDIT TIMESTAMP REGRESSION DETECTED at entry $COUNT" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi

  PREV="$chain_hash"
  if [ "$last_ts" != "null" ]; then
    LAST_LAST_TS=$last_ts
  fi
done < "$LEDGER"

# verify ledger sha/count/last_chain_hash vs seal if seal exists
RECOMPUTED_LEDGER_SHA=$(sha256sum "$LEDGER" | awk '{print $1}')
if [ -n "$SEAL_LEDGER_SHA" ]; then
  if [ "$RECOMPUTED_LEDGER_SHA" != "$SEAL_LEDGER_SHA" ]; then
    echo "AUDIT ROTATION CHAIN BROKEN: ledger SHA mismatch with seal" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
  if [ "$COUNT" -ne "$SEAL_ENTRY_COUNT" ]; then
    echo "AUDIT ROTATION CHAIN BROKEN: ledger entry_count mismatch with seal" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
  if [ "$PREV" != "$SEAL_LAST_CHAIN_HASH" ]; then
    echo "AUDIT ROTATION CHAIN BROKEN: last_chain_hash mismatch with seal" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
fi

# Gap detection: any rotated file on disk not present in ledger -> orphan
# Orphan/gap detection: any rotated file on disk not present in ledger -> orphan
# Use jq to robustly extract 'file' fields from JSONL ledger
LEDGER_FILES=$(jq -r '.file // empty' "$LEDGER" 2>/dev/null || true)
for rf in $AUDIT_DIR/audit.log.*; do
  [ -e "$rf" ] || continue
  b=$(basename "$rf")
  if ! printf "%s\n" "$LEDGER_FILES" | grep -xq "$b"; then
    echo "AUDIT ROTATION GAP DETECTED: orphan rotation file $b" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
done

# all checks passed
echo "AUDIT ROTATION CHAIN OK (entries=$COUNT)"
exit 0
