#!/usr/bin/env bash
set -euo pipefail

AUDIT_DIR="/var/log/kubernetes/audit"
OFFLOAD_DIR="$AUDIT_DIR/offloaded"
AWS_BIN=$(command -v aws || true)

if [ -z "$AWS_BIN" ]; then
  echo "ERROR: aws CLI not found in PATH" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

: ${AWS_REGION:?Environment variable AWS_REGION must be set}
: ${AUDIT_S3_BUCKET:?Environment variable AUDIT_S3_BUCKET must be set}

mkdir -p "$OFFLOAD_DIR"

# Consider rotated files: audit.log.1, audit.log.2.gz, audit.log.* excluding "audit.log"
shopt -s nullglob
FILES=("$AUDIT_DIR"/audit.log.*)
shopt -u nullglob

if [ ${#FILES[@]} -eq 0 ]; then
  echo "No rotated audit files to offload."
  exit 0
fi

for f in "${FILES[@]}"; do
  base=$(basename "$f")
  target="s3://$AUDIT_S3_BUCKET/$base"

  # Skip if file already moved to offloaded dir
  if [ -f "$OFFLOAD_DIR/$base" ]; then
    echo "SKIP: $base already moved to offloaded directory"
    continue
  fi

  echo "Uploading $f -> $target"
  # Idempotent: use aws s3 cp (will fail if network/permission issues)
  "$AWS_BIN" s3 cp "$f" "$target" --region "$AWS_REGION" --storage-class STANDARD_IA --sse AES256

  echo "Moving $f to $OFFLOAD_DIR"
  mv "$f" "$OFFLOAD_DIR/"
done

exit 0
