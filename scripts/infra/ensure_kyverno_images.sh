#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIGN_SCRIPT="${REPO_ROOT}/scripts/supply_chain/sign_images.sh"
THREADFORGE_REGISTRY_USER="${THREADFORGE_REGISTRY_USER:-threadforge}"
THREADFORGE_REGISTRY_PASSWORD="${THREADFORGE_REGISTRY_PASSWORD:-threadforge-dev-password}"
REGISTRY_CREDS="${THREADFORGE_REGISTRY_USER}:${THREADFORGE_REGISTRY_PASSWORD}"

command -v skopeo >/dev/null 2>&1 || { echo "[FAIL] skopeo not found" >&2; exit 10; }
[ -x "$SIGN_SCRIPT" ] || { echo "[FAIL] signing helper missing: $SIGN_SCRIPT" >&2; exit 10; }

REGISTRY_CERT_DIR="$(mktemp -d)"
cleanup_registry_cert_dir() {
  rm -rf "$REGISTRY_CERT_DIR"
}
trap cleanup_registry_cert_dir EXIT
cp "$REGISTRY_CA_CERT_PATH" "$REGISTRY_CERT_DIR/ca.crt"

ensure_internal_image() {
  local source_ref="$1"
  local target_repo="$2"
  local expected_digest="$3"
  local target_ref="${target_repo}:sha256-${expected_digest#sha256:}"
  local digest_ref="${target_repo}@${expected_digest}"
  local current_digest=""

  current_digest="$(skopeo inspect --creds "$REGISTRY_CREDS" --tls-verify=true --cert-dir "$REGISTRY_CERT_DIR" --format '{{.Digest}}' "docker://${digest_ref}" 2>/dev/null || true)"
  if [ "$current_digest" != "$expected_digest" ]; then
    skopeo copy --all --preserve-digests --src-no-creds --dest-creds "$REGISTRY_CREDS" --dest-tls-verify=true --dest-cert-dir "$REGISTRY_CERT_DIR" \
      "docker://${source_ref}" "docker://${target_ref}" >/dev/null
    current_digest="$(skopeo inspect --creds "$REGISTRY_CREDS" --tls-verify=true --cert-dir "$REGISTRY_CERT_DIR" --format '{{.Digest}}' "docker://${digest_ref}")"
  fi

  if [ "$current_digest" != "$expected_digest" ]; then
    echo "[FAIL] mirrored digest mismatch for ${digest_ref}: expected ${expected_digest}, got ${current_digest}" >&2
    exit 2
  fi
}

ensure_internal_image "ghcr.io/kyverno/kyverno:v1.12.6" "registry.threadforge.local:30500/kyverno/kyverno" "sha256:2e1af149ebf318b67233c519225b403ca0500c657b347553c74627ccb6f369f7"
ensure_internal_image "ghcr.io/kyverno/kyvernopre:v1.12.6" "registry.threadforge.local:30500/kyverno/kyvernopre" "sha256:94e787023a71c1a2850388a9fe190b45156684fe7f20f59132edfe6b57e17d31"
ensure_internal_image "ghcr.io/kyverno/background-controller:v1.12.6" "registry.threadforge.local:30500/kyverno/background-controller" "sha256:148e3f0f5f0c84f3cf1428f5460b680c15d1e190f3e6182e2e02ff177071a5be"
ensure_internal_image "ghcr.io/kyverno/cleanup-controller:v1.12.6" "registry.threadforge.local:30500/kyverno/cleanup-controller" "sha256:72be48bd94266ae87f9ad6567d8f8a6c1ef6ca173adb8c8bcceab7c1c9b9a242"
ensure_internal_image "ghcr.io/kyverno/reports-controller:v1.12.6" "registry.threadforge.local:30500/kyverno/reports-controller" "sha256:aa878cc71678d45d63775a0014244b5d238dfcfcd4e79ad8be3158d08e7b71b2"
ensure_internal_image "docker.io/bitnami/kubectl@sha256:a84ef19c1c38286cb674c90182bd8b4e1d11ed4e089e5994f553cbe5d67d9068" "registry.threadforge.local:30500/mirror/docker.io/bitnami/kubectl" "sha256:a84ef19c1c38286cb674c90182bd8b4e1d11ed4e089e5994f553cbe5d67d9068"

for image_ref in \
  "registry.threadforge.local:30500/kyverno/kyverno@sha256:2e1af149ebf318b67233c519225b403ca0500c657b347553c74627ccb6f369f7" \
  "registry.threadforge.local:30500/kyverno/kyvernopre@sha256:94e787023a71c1a2850388a9fe190b45156684fe7f20f59132edfe6b57e17d31" \
  "registry.threadforge.local:30500/kyverno/background-controller@sha256:148e3f0f5f0c84f3cf1428f5460b680c15d1e190f3e6182e2e02ff177071a5be" \
  "registry.threadforge.local:30500/kyverno/cleanup-controller@sha256:72be48bd94266ae87f9ad6567d8f8a6c1ef6ca173adb8c8bcceab7c1c9b9a242" \
  "registry.threadforge.local:30500/kyverno/reports-controller@sha256:aa878cc71678d45d63775a0014244b5d238dfcfcd4e79ad8be3158d08e7b71b2" \
  "registry.threadforge.local:30500/mirror/docker.io/bitnami/kubectl@sha256:a84ef19c1c38286cb674c90182bd8b4e1d11ed4e089e5994f553cbe5d67d9068"; do
  "$SIGN_SCRIPT" --mode sign --image "$image_ref" >/dev/null
done

echo "[PASS] Kyverno images mirrored with preserved digests and signatures"
