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

ensure_internal_image "quay.io/metallb/controller@sha256:faa8f0d53b3811705910f823f895f797a68729a0fe1f38e36e4a25efeab303bd" "registry.threadforge.local:30500/metallb/controller" "sha256:faa8f0d53b3811705910f823f895f797a68729a0fe1f38e36e4a25efeab303bd"
ensure_internal_image "quay.io/metallb/speaker@sha256:b73cc85aaf693bb283cec2b9b14acf788fcf78acd23ae999013b512d37d8a946" "registry.threadforge.local:30500/metallb/speaker" "sha256:b73cc85aaf693bb283cec2b9b14acf788fcf78acd23ae999013b512d37d8a946"
ensure_internal_image "quay.io/frrouting/frr@sha256:6959404cfe5878c641d5619b7348f5b0efb7968ac6e00f1aa42cbf269aa2ddc6" "registry.threadforge.local:30500/frrouting/frr" "sha256:6959404cfe5878c641d5619b7348f5b0efb7968ac6e00f1aa42cbf269aa2ddc6"

for image_ref in \
  "registry.threadforge.local:30500/metallb/controller@sha256:faa8f0d53b3811705910f823f895f797a68729a0fe1f38e36e4a25efeab303bd" \
  "registry.threadforge.local:30500/metallb/speaker@sha256:b73cc85aaf693bb283cec2b9b14acf788fcf78acd23ae999013b512d37d8a946" \
  "registry.threadforge.local:30500/frrouting/frr@sha256:6959404cfe5878c641d5619b7348f5b0efb7968ac6e00f1aa42cbf269aa2ddc6"; do
  "$SIGN_SCRIPT" --mode sign --image "$image_ref" >/dev/null
done

echo "[PASS] MetalLB images mirrored with preserved digests and signatures"
