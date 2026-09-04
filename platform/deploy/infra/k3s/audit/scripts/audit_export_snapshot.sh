#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="$(pwd)"
LEDGER="/home/threadforge/threadforge/platform/deploy/infra/k3s/audit/AUDIT_ROTATION_LEDGER.jsonl"
SEAL="/home/threadforge/threadforge/platform/deploy/infra/k3s/audit/AUDIT_LEDGER_SEAL.json"
AUDIT_DIR="/var/log/kubernetes/audit"

TS=$(date +%Y%m%dT%H%M%SZ)
OUT="${OUT_DIR}/audit_snapshot_${TS}.tar.gz"
TMPDIR=$(mktemp -d)

if [ ! -f "$LEDGER" ] || [ ! -s "$LEDGER" ]; then
  echo "ERROR: ledger missing or empty" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
if [ ! -f "$SEAL" ] || [ ! -s "$SEAL" ]; then
  echo "ERROR: seal missing or empty" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

cp "$LEDGER" "$TMPDIR/"
cp "$SEAL" "$TMPDIR/"

# include most recent 3 rotated files if present
shopt -s nullglob
ROT=("$AUDIT_DIR"/audit.log.*)
shopt -u nullglob

count=0
for f in $(printf "%s\n" "${ROT[@]}" | sort -r); do
  if [ $count -ge 3 ]; then break; fi
  cp "$f" "$TMPDIR/"
  count=$((count+1))
done

# manifest with internal SHAs
MANIFEST="$TMPDIR/manifest.json"
jq -n --arg ledger_sha "$(sha256sum "$LEDGER" | awk '{print $1}')" --arg ledger_file "$(basename "$LEDGER")" --arg seal_file "$(basename "$SEAL")" --argjson rotated_count "$count" '{ledger_sha256:$ledger_sha,ledger_file:$ledger_file,seal_file:$seal_file,rotated_count:$rotated_count}' > "$MANIFEST"

# create tarball
tar -C "$TMPDIR" -czf "$OUT" .
rm -rf "$TMPDIR"

echo "$OUT"
exit 0
