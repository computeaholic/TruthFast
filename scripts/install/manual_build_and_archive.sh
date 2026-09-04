#!/usr/bin/env bash
set -euo pipefail
# Usage: ./scripts/manual_build_and_archive.sh IMAGE_NAME CONTEXT_DIR
# Example: ./scripts/manual_build_and_archive.sh registry.threadforge.local:30500/myrepo/myimage:tag .
IMAGE=${1:?image}
CONTEXT=${2:-.}
ARCHIVE_DIR=${3:-./out/manual-archive}
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REGISTRY_CA_CERT_PATH="${REGISTRY_CA_CERT_PATH:-$REPO_ROOT/certs/threadforge-ingress-ca.crt}"
REGISTRY_CERT_DIR="$(dirname "$REGISTRY_CA_CERT_PATH")"
mkdir -p "$ARCHIVE_DIR"

if [[ ! -f "$REGISTRY_CA_CERT_PATH" ]]; then
  echo "[FAIL] registry CA cert missing: $REGISTRY_CA_CERT_PATH"
  exit 2
fi

echo "Building $IMAGE from context $CONTEXT"
docker buildx build --builder threadforge-builder --platform linux/amd64 --push -t "$IMAGE" "$CONTEXT"

# Record digest
FULL_DIGEST=$(skopeo inspect --tls-verify=true --cert-dir "$REGISTRY_CERT_DIR" --format '{{.Name}}@{{.Digest}}' "docker://$IMAGE")
DIGEST=${FULL_DIGEST##*@}
echo "Pushed digest: $DIGEST"

# Archive using skopeo (requires skopeo installed and accessible)
ARCHIVE_PATH="$ARCHIVE_DIR/$(echo "$IMAGE" | tr ":/" "__")@${DIGEST}.oci"
echo "Archiving to $ARCHIVE_PATH"
skopeo copy --tls-verify=true --cert-dir "$REGISTRY_CERT_DIR" --format oci docker://$IMAGE oci:$ARCHIVE_PATH

# Create checksum
tarball="$ARCHIVE_PATH.tar"
if [ -f "$tarball" ]; then
  sha256sum "$tarball" > "$tarball.sha256"
  echo "Archive sha256 written to $tarball.sha256"
else
  echo "Archive output $tarball not found; skopeo may have created directory layout instead"
fi

echo "Manual build+archive completed: $IMAGE -> $ARCHIVE_PATH"
