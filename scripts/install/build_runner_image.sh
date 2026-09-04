#!/usr/bin/env bash
# Authority Domain: operator_infra
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 <tag>

Build and push the runner image using the Dockerfile at platform/images/actions-runner/Dockerfile.
Tag: registry.threadforge.local:30500/actions-runner:<tag>

Example:
  $0 make-20260125-tf-a15f117a

Outputs the final image digest (sha256:...) to stdout.
EOF
}

if [ "${1:-}" = "" ]; then
  usage
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
TAG="$1"
IMAGE="registry.threadforge.local:30500/actions-runner:${TAG}"
BUILD_CONTEXT="platform/images/actions-runner"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REGISTRY_CA_CERT_PATH="${REGISTRY_CA_CERT_PATH:-$REPO_ROOT/certs/threadforge-ingress-ca.crt}"
REGISTRY_CERT_DIR="$(dirname "$REGISTRY_CA_CERT_PATH")"

if [ ! -f "$REGISTRY_CA_CERT_PATH" ]; then
  echo "[FAIL] registry CA cert missing: $REGISTRY_CA_CERT_PATH"
  exit 2
fi

echo "Building image: ${IMAGE} from ${BUILD_CONTEXT}"
docker buildx build --builder threadforge-builder --platform linux/amd64 --push -t "${IMAGE}" "${BUILD_CONTEXT}"

echo "Resolving pushed digest: ${IMAGE}"
DIGEST=$(skopeo inspect --tls-verify=true --cert-dir "$REGISTRY_CERT_DIR" --format '{{.Digest}}' "docker://${IMAGE}" 2>/dev/null || true)

if [ -z "${DIGEST}" ]; then
  echo "WARNING: Could not determine image digest automatically. Please record the digest reported by your registry." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "PUSHED: ${IMAGE}@${DIGEST}"
# Print digest alone as a machine friendly line
echo "DIGEST: ${DIGEST}"

# End
