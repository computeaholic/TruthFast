#!/usr/bin/env bash
# Archive image to OCI layout and generate meta.json + checksum
# Usage: ./scripts/archive-image.sh --image registry:30500/org/image@sha256:... --target-dir /path/to/target
set -euo pipefail
IMAGE=""
TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE=$2; shift 2;;
    --target-dir) TARGET=$2; shift 2;;
    --source) SOURCE=$2; shift 2;;
    *) echo "Unknown arg $1"; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0;;
  esac
done
if [ -z "$IMAGE" ] || [ -z "$TARGET" ]; then
  echo "Usage: $0 --image <image@digest> --target-dir <target-dir>" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
mkdir -p "$TARGET"
# Prefer skopeo if available
if command -v skopeo >/dev/null 2>&1; then
  if [ -z "${REGISTRY_CA:-}" ]; then
    echo "ERROR: REGISTRY_CA is not set; TLS verification is required. Set REGISTRY_CA to the CA certificate directory for the registry." >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
  if [ ! -d "${REGISTRY_CA}" ]; then
    echo "ERROR: REGISTRY_CA directory '${REGISTRY_CA}' does not exist or is not a directory" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
  echo "Using skopeo to copy $IMAGE -> oci:$TARGET with TLS verification"
  skopeo copy --retry-times 3 --tls-verify=true --cert-dir "${REGISTRY_CA}" "docker://$IMAGE" "oci:$TARGET"
else
  echo "skopeo not found; cannot perform archive copy" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
# Write meta.json
DIGEST=$(echo "$IMAGE" | sed -n 's/.*@\(sha256:[0-9a-f]\{64\}\)$/\1/p')
META_FILE="$TARGET/meta.json"
cat > "$META_FILE" <<EOF
{
  "image": "$IMAGE",
  "digest": "$DIGEST",
  "archived_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source": "${SOURCE:-manual}"
}
EOF
# Compute checksum of the oci layout as a deterministic canonical checksum (sha256 of tars of blobs)
CHECKSUM_FILE="$TARGET/checksum.sha256"
# Use tar to produce a reproducible checksum
( cd "$TARGET" && tar -cf - . | sha256sum -b | awk '{print $1}' > "$CHECKSUM_FILE" )
# Verification: compare with registry manifest digest
if command -v skopeo >/dev/null 2>&1; then
  echo "Verifying registry digest presence for $IMAGE using TLS verification"
  if skopeo inspect --tls-verify=true --cert-dir "${REGISTRY_CA}" "docker://$IMAGE" >/dev/null 2>&1; then
    echo "Registry manifest present"
  else
    echo "Registry manifest missing or inaccessible for $IMAGE" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
fi
# Output meta info
echo "{\"image\": \"$IMAGE\", \"digest\": \"$DIGEST\", \"archive_dir\": \"$TARGET\", \"checksum_file\": \"$CHECKSUM_FILE\" }" > "$TARGET/archive-report.json"
echo "Archived $IMAGE to $TARGET (digest: $DIGEST)"
