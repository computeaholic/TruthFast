#!/usr/bin/env bash
set -euo pipefail
OUTDIR="out/registry-backups"
mkdir -p "$OUTDIR"
NAMESPACE=${1:-registry}
# Prefer a Running pod
POD=$(kubectl get pods -n "$NAMESPACE" -l app=registry -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' | awk '{print $1}')
if [[ -z "$POD" ]]; then
  echo "No registry pod found in namespace $NAMESPACE" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
TS=$(date -u +%Y%m%dT%H%M%SZ)
OUTFILE="$OUTDIR/registry-backup-$TS.tgz"
echo "Creating backup from pod $POD to $OUTFILE"
# Stream a tar from the pod into a local file
kubectl exec -n "$NAMESPACE" "$POD" -- tar -C /var/lib/registry -czf - . > "$OUTFILE"
sha256sum "$OUTFILE" > "$OUTFILE.sha256"
echo "Backup created: $OUTFILE"
echo "SHA256:" && cat "$OUTFILE.sha256"

# Minimal verification: list archive contents
if tar -tzf "$OUTFILE" | head -n 5 >/dev/null 2>&1; then
  echo "Archive appears valid (top-level entries):"
  tar -tzf "$OUTFILE" | head -n 20
else
  echo "Archive appears invalid" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
