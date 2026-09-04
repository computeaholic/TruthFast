#!/usr/bin/env bash
set -euo pipefail

AUDIT_DIR="/var/log/kubernetes/audit"
LEDGER="/home/threadforge/threadforge/platform/deploy/infra/k3s/audit/AUDIT_ROTATION_LEDGER.jsonl"

# Ensure ledger exists and normalize any pretty-printed JSON entries to JSONL (one-line per entry)
mkdir -p "$(dirname "$LEDGER")"
if [ ! -f "$LEDGER" ]; then
  touch "$LEDGER"
  chmod 0644 "$LEDGER"
else
  # If file contains multi-line JSON (pretty-printed single object), compact it
  # and ensure ledger is JSONL (one entry per line). This preserves existing data.
  if awk 'NR==1{if($0 ~ /^{/) print "ok"}' "$LEDGER" | grep -q "ok"; then
    # try to parse and compact entire file to single-line JSON if valid
    if jq -c . "$LEDGER" >/dev/null 2>&1; then
      jq -c . "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
    fi
  fi
fi

# Find rotated files (exclude live audit.log)
shopt -s nullglob
FILES=("$AUDIT_DIR"/audit.log.*)
shopt -u nullglob

if [ ${#FILES[@]} -eq 0 ]; then
  # nothing to do
  exit 0
fi

# Helper to compute sha256
file_sha256(){ sha256sum "$1" | awk '{print $1}'; }

# Get last chain hash from ledger
LAST_CHAIN_HASH=""
if [ -s "$LEDGER" ]; then
  # read last non-empty line's chain_hash
  LAST_CHAIN_HASH=$(awk 'NF{line=$0}END{print line}' "$LEDGER" | jq -r '.chain_hash')
fi
if [ -z "$LAST_CHAIN_HASH" ]; then
  LAST_CHAIN_HASH="GENESIS"
fi

for f in "${FILES[@]}"; do
  base=$(basename "$f")
  # Skip if already recorded in ledger
  if grep -q "\"file\": \"$base\"" "$LEDGER" 2>/dev/null; then
    continue
  fi

  SHA=$(file_sha256 "$f")
  SIZE=$(stat -c%s "$f")
  INODE=$(stat -c%i "$f")
  DEVICE=$(stat -c%d "$f")

  # Extract first and last event timestamps from file (if present)
  FIRST_TS=$(awk 'NR==1{if(match($0,/"requestReceivedTimestamp":"([^\"]+)"/,a)){cmd="date -d \""a[1]"\" +%s";cmd|getline t;close(cmd);print t;exit}}' "$f" || true)
  LAST_TS=$(tac "$f" | awk ' { if(match($0,/"requestReceivedTimestamp":"([^\"]+)"/,a)){cmd="date -d \""a[1]"\" +%s";cmd|getline t;close(cmd);print t;exit}}' || true)
  FIRST_TS=${FIRST_TS:-null}
  LAST_TS=${LAST_TS:-null}

  PREV_HASH="$LAST_CHAIN_HASH"
  CHAIN_HASH=$(printf "%s%s" "$PREV_HASH" "$SHA" | sha256sum | awk '{print $1}')

  # Build ledger entry JSON via jq
  ENTRY=$(jq -c -n \
    --arg rotation_timestamp "$(date --iso-8601=seconds)" \
    --arg file "$base" \
    --arg sha256 "$SHA" \
    --argjson size_bytes "$SIZE" \
    --arg inode "$INODE" \
    --arg device "$DEVICE" \
    --arg first_event_ts "${FIRST_TS:-null}" \
    --arg last_event_ts "${LAST_TS:-null}" \
    --arg previous_chain_hash "$PREV_HASH" \
    --arg chain_hash "$CHAIN_HASH" \
    '{rotation_timestamp:$rotation_timestamp,file:$file,sha256:$sha256,size_bytes:$size_bytes,inode:$inode,device:$device,first_event_ts:$first_event_ts,last_event_ts:$last_event_ts,previous_chain_hash:$previous_chain_hash,chain_hash:$chain_hash}')

  # Append to ledger (append-only)
  echo "$ENTRY" >> "$LEDGER"
  # update LAST_CHAIN_HASH for next
  LAST_CHAIN_HASH="$CHAIN_HASH"

done

# After appending entries, compute ledger seal (sha, count, last_chain_hash)
LEDGER_SHA=$(sha256sum "$LEDGER" | awk '{print $1}')
ENTRY_COUNT=$(wc -l < "$LEDGER" | tr -d ' ')
LAST_CHAIN_HASH_FINAL="$LAST_CHAIN_HASH"
SEAL_FILE="/home/threadforge/threadforge/platform/deploy/infra/k3s/audit/AUDIT_LEDGER_SEAL.json"
jq -n \
  --arg ledger_sha256 "$LEDGER_SHA" \
  --argjson entry_count "$ENTRY_COUNT" \
  --arg last_chain_hash "$LAST_CHAIN_HASH_FINAL" \
  --arg generated_at "$(date --iso-8601=seconds)" \
  '{ledger_sha256:$ledger_sha256,entry_count:$entry_count,last_chain_hash:$last_chain_hash,generated_at:$generated_at}' \
  > "$SEAL_FILE"
chmod 0644 "$SEAL_FILE"

exit 0
