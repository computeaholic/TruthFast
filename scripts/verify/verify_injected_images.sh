#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/fail.sh
source "$REPO_ROOT/scripts/lib/fail.sh"
CURRENT_SOURCE_SHA="$(git rev-parse HEAD 2>/dev/null || true)"
PROOF_SIGNATURE_CACHE_PATH="${PROOF_SIGNATURE_CACHE_PATH:-$REPO_ROOT/artifacts/proof/latest/signature_verification_cache.json}"

COSIGN_PUBLIC_KEY_PATH="${COSIGN_PUBLIC_KEY_PATH:-${HOME}/.threadforge-signing/cosign.pub}"
ALLOWED_IMAGE_PREFIX="${ALLOWED_IMAGE_PREFIX:-registry.threadforge.local:30500/}"
COLLECT_INJECTED_SCRIPT="${COLLECT_INJECTED_SCRIPT:-$REPO_ROOT/scripts/proof/collect_injected_images.sh}"
INJECTED_SOURCE_HASH_EXPECTED="${INJECTED_SOURCE_HASH_EXPECTED:-}"
REGISTRY_CA_CERT_PATH="${REGISTRY_CA_CERT_PATH:-$REPO_ROOT/certs/threadforge-ingress-ca.crt}"

if ! command -v kubectl >/dev/null 2>&1; then
  fail_system "kubectl not found in PATH"
fi
if ! command -v cosign >/dev/null 2>&1; then
  fail_system "cosign not found in PATH"
fi
if [ ! -f "$COSIGN_PUBLIC_KEY_PATH" ]; then
  fail_system "cosign public key missing: $COSIGN_PUBLIC_KEY_PATH"
fi
if [ ! -x "$COLLECT_INJECTED_SCRIPT" ]; then
  fail_system "collect_injected_images script missing or not executable: $COLLECT_INJECTED_SCRIPT"
fi
if [ ! -f "$REGISTRY_CA_CERT_PATH" ]; then
  fail_system "registry CA cert missing: $REGISTRY_CA_CERT_PATH"
fi

export SSL_CERT_FILE="$REGISTRY_CA_CERT_PATH"
export SSL_CERT_DIR="${SSL_CERT_DIR:-/etc/ssl/certs}"

injector_out_file="$(mktemp)"
cleanup() {
  rm -f "$injector_out_file"
}
trap cleanup EXIT

"$COLLECT_INJECTED_SCRIPT" > "$injector_out_file"

mapfile -t injected_images < <(awk -F= '/^INJECTED_IMAGE=/{print $2}' "$injector_out_file")
mapfile -t injected_hashes < <(awk -F= '/^HASH=/{print $2}' "$injector_out_file" | sort -u)

declare -A verified_signature_cache=()
if [ -f "$PROOF_SIGNATURE_CACHE_PATH" ]; then
  while IFS= read -r verified_ref; do
    [ -n "$verified_ref" ] || continue
    verified_signature_cache["$verified_ref"]=1
  done < <(python3 - "$PROOF_SIGNATURE_CACHE_PATH" "$CURRENT_SOURCE_SHA" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
current_sha = (sys.argv[2] or "").strip()
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)

if str(payload.get("source_sha") or "").strip() != current_sha:
    raise SystemExit(0)

for ref in payload.get("verified_images", []):
    if isinstance(ref, str) and ref.strip():
        print(ref.strip())
PY
  )
fi

if [ "${#injected_images[@]}" -eq 0 ]; then
  fail_policy "no injected images resolved"
fi

if [ "${#injected_hashes[@]}" -ne 1 ]; then
  fail_policy "injected image source hash is ambiguous"
fi

if [ -n "$INJECTED_SOURCE_HASH_EXPECTED" ] && [ "${injected_hashes[0]}" != "$INJECTED_SOURCE_HASH_EXPECTED" ]; then
  fail_policy "injected image source hash drift detected"
fi

echo "[verify_injected_images] verifying ${#injected_images[@]} injected image reference(s)"
for image_ref in "${injected_images[@]}"; do
  if [[ ! "$image_ref" =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
    fail_policy "injected image is not canonical digest form: $image_ref"
  fi
  if [[ "$image_ref" != "$ALLOWED_IMAGE_PREFIX"* ]]; then
    fail_policy "injected image is not in local registry: $image_ref"
  fi
  if [ -n "${verified_signature_cache[$image_ref]+x}" ]; then
    echo "[verify_injected_images] cache hit: $image_ref"
    continue
  fi
  if ! cosign verify --key "$COSIGN_PUBLIC_KEY_PATH" --rekor-url https://rekor.sigstore.dev "$image_ref" >/dev/null 2>&1; then
    fail_policy "injected image unsigned or invalid signature: $image_ref"
  fi
done

echo "[PASS] injected sidecar image references are digest-pinned, local, and signed"
echo "INJECTED_IMAGES_LOCKED=TRUE"
