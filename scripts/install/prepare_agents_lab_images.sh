#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LAB_DIR="${REPO_ROOT}/platform/labs/agent-containment"
K8S_DIR="${LAB_DIR}/k8s"
SRC_DEPLOYMENTS="${K8S_DIR}/deployments.yaml"
RESOLVED_DEPLOYMENTS="${AGENTS_RESOLVED_DEPLOYMENTS:-${K8S_DIR}/deployments.resolved.yaml}"

REGISTRY_BASE="registry.threadforge.local:30500/agents-lab"
THREADFORGE_REGISTRY_USER="${THREADFORGE_REGISTRY_USER:-threadforge}"
THREADFORGE_REGISTRY_PASSWORD="${THREADFORGE_REGISTRY_PASSWORD:-threadforge-dev-password}"
IMAGE_OS="${AGENTS_IMAGE_OS:-linux}"
IMAGE_ARCH="${AGENTS_IMAGE_ARCH:-arm64}"
TAG="${AGENTS_IMAGE_TAG:-audit-$(git -C "${REPO_ROOT}" rev-parse --short=12 HEAD)}"
SOURCE_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
REGISTRY_CA_CERT_PATH="${REGISTRY_CA_CERT_PATH:-${REPO_ROOT}/certs/threadforge-ingress-ca.crt}"
SIGN_SCRIPT="${REPO_ROOT}/scripts/supply_chain/sign_images.sh"
REGISTRY_CERT_DIR=""

if [[ ! -f "$REGISTRY_CA_CERT_PATH" ]]; then
  echo "[FAIL] registry CA cert missing: $REGISTRY_CA_CERT_PATH" >&2
  exit 2
fi

REGISTRY_CERT_DIR="$(mktemp -d)"
cleanup_registry_cert_dir() {
  rm -rf "$REGISTRY_CERT_DIR"
}
trap cleanup_registry_cert_dir EXIT
cp "$REGISTRY_CA_CERT_PATH" "$REGISTRY_CERT_DIR/ca.crt"

inspect_image_digest() {
  local image_ref="$1"
  skopeo inspect \
    --tls-verify=true \
    --cert-dir "$REGISTRY_CERT_DIR" \
    --creds "${THREADFORGE_REGISTRY_USER}:${THREADFORGE_REGISTRY_PASSWORD}" \
    --override-os "${IMAGE_OS}" \
    --override-arch "${IMAGE_ARCH}" \
    --format '{{.Name}}@{{.Digest}}' \
    "docker://${image_ref}" 2>/dev/null || true
}

build_and_push() {
  local name="$1"
  local context_dir="$2"
  local tagged_image="${REGISTRY_BASE}/${name}:${TAG}"
  local digest_ref

  echo "[AGENTS] Building ${tagged_image}" >&2
  docker buildx build --builder threadforge-builder --platform "${IMAGE_OS}/${IMAGE_ARCH}" --push -t "${tagged_image}" "${context_dir}" >/dev/null

  digest_ref="$(inspect_image_digest "${tagged_image}")"
  if [[ -z "${digest_ref}" || "${digest_ref}" != *@sha256:* ]]; then
    echo "[FAIL] Could not resolve digest for ${tagged_image}" >&2
    exit 2
  fi

  if [[ ! -x "${SIGN_SCRIPT}" ]]; then
    echo "[FAIL] signing helper missing: ${SIGN_SCRIPT}" >&2
    exit 10
  fi
  SIGN_IMAGES_OS="${IMAGE_OS}" SIGN_IMAGES_ARCH="${IMAGE_ARCH}" \
    "${SIGN_SCRIPT}" --mode sign --image "${digest_ref}" >/dev/null
  SIGN_IMAGES_OS="${IMAGE_OS}" SIGN_IMAGES_ARCH="${IMAGE_ARCH}" \
    "${SIGN_SCRIPT}" --mode verify --image "${digest_ref}" >/dev/null

  echo "${digest_ref}"
}

RESEARCH_IMAGE="$(build_and_push research-agent "${LAB_DIR}/agents/research-agent")"
WRITER_IMAGE="$(build_and_push writer-agent "${LAB_DIR}/agents/writer-agent")"
ATTACKER_IMAGE="$(build_and_push attacker-agent "${LAB_DIR}/agents/attacker-agent")"
ROGUE_IMAGE="$(build_and_push rogue-agent "${LAB_DIR}/agents/rogue-agent")"

echo "[AGENTS] Rendering resolved deployment manifest: ${RESOLVED_DEPLOYMENTS}" >&2
cp "${SRC_DEPLOYMENTS}" "${RESOLVED_DEPLOYMENTS}"
sed -i "s/THREADFORGE_SOURCE_SHA/${SOURCE_SHA}/g" "${RESOLVED_DEPLOYMENTS}"

sed -i -E "s#image:[[:space:]]*registry\.threadforge\.local:30500/agents-lab/research-agent@sha256:[a-f0-9]{64}#image: ${RESEARCH_IMAGE}#" "${RESOLVED_DEPLOYMENTS}"
sed -i -E "s#image:[[:space:]]*registry\.threadforge\.local:30500/agents-lab/writer-agent@sha256:[a-f0-9]{64}#image: ${WRITER_IMAGE}#" "${RESOLVED_DEPLOYMENTS}"
sed -i -E "s#image:[[:space:]]*registry\.threadforge\.local:30500/agents-lab/attacker-agent@sha256:[a-f0-9]{64}#image: ${ATTACKER_IMAGE}#" "${RESOLVED_DEPLOYMENTS}"
sed -i -E "s#image:[[:space:]]*registry\.threadforge\.local:30500/agents-lab/rogue-agent@sha256:[a-f0-9]{64}#image: ${ROGUE_IMAGE}#" "${RESOLVED_DEPLOYMENTS}"

echo "RESEARCH_IMAGE=${RESEARCH_IMAGE}"
echo "WRITER_IMAGE=${WRITER_IMAGE}"
echo "ATTACKER_IMAGE=${ATTACKER_IMAGE}"
echo "ROGUE_IMAGE=${ROGUE_IMAGE}"
echo "RESOLVED_DEPLOYMENTS=${RESOLVED_DEPLOYMENTS}"
echo "SOURCE_SHA=${SOURCE_SHA}"
