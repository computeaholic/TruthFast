#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/registry_probe.sh"
FORGESEC_IMAGE="${FORGESEC_IMAGE:-registry.threadforge.local:30500/forgesec:v2}"
FORGESEC_BUILDER="${FORGESEC_BUILDER:-threadforge-builder}"
REGISTRY_CA_CERT_PATH="${REGISTRY_CA_CERT_PATH:-$REPO_ROOT/certs/threadforge-ingress-ca.crt}"
REGISTRY_CERT_DIR="$(mktemp -d)"
THREADFORGE_REGISTRY_USER="${THREADFORGE_REGISTRY_USER:-threadforge}"
THREADFORGE_REGISTRY_PASSWORD="${THREADFORGE_REGISTRY_PASSWORD:-threadforge-dev-password}"
FORGESEC_VERIFY_BUILD_DETERMINISM="${FORGESEC_VERIFY_BUILD_DETERMINISM:-0}"
FORGESEC_SOURCE_DATE_EPOCH="${FORGESEC_SOURCE_DATE_EPOCH:-1777334400}"

cleanup_registry_cert_dir() {
  rm -rf "$REGISTRY_CERT_DIR"
}
trap cleanup_registry_cert_dir EXIT

if [[ ! -f "$REGISTRY_CA_CERT_PATH" ]]; then
  echo "[FAIL] registry CA cert missing: $REGISTRY_CA_CERT_PATH" >&2
  exit 2
fi
cp "$REGISTRY_CA_CERT_PATH" "$REGISTRY_CERT_DIR/ca.crt"
registry_probe_reconcile_host_dns "${FORGESEC_IMAGE%%:*}" "${REGISTRY_CONTAINER:-threadforge-registry}"

canonical_ref="$({
  python3 - "$REPO_ROOT/platform/deploy/forgesec/identity-job.yaml" "$REPO_ROOT/platform/deploy/forgesec/surface-job.yaml" <<'PY'
import re
import sys
from pathlib import Path

refs = []
for path in sys.argv[1:]:
    text = Path(path).read_text(encoding="utf-8")
    match = re.search(r'^\s*image:\s*([^\s]+)\s*$', text, re.MULTILINE)
    if not match:
        raise SystemExit(f"missing image in {path}")
    refs.append(match.group(1).strip())
if len(set(refs)) != 1:
    raise SystemExit("ForgeSec manifests do not share a single canonical image reference")
print(refs[0])
PY
})"

if [[ ! "$canonical_ref" =~ ^registry\.threadforge\.local:30500/.+@sha256:[a-f0-9]{64}$ ]]; then
  echo "[FAIL] canonical ForgeSec reference must be a digest-pinned internal image" >&2
  echo "[FAIL] manifest=$canonical_ref" >&2
  exit 2
fi

resolved_digest="$(skopeo inspect --tls-verify=true --cert-dir "$REGISTRY_CERT_DIR" --creds "${THREADFORGE_REGISTRY_USER}:${THREADFORGE_REGISTRY_PASSWORD}" --format '{{.Digest}}' "docker://${canonical_ref}" 2>/dev/null || true)"
canonical_digest="${canonical_ref##*@}"

if [[ -z "$resolved_digest" ]]; then
  echo "[FAIL] canonical ForgeSec manifest image is missing from the internal registry" >&2
  echo "[FAIL] manifest=$canonical_ref" >&2
  exit 2
fi

if [[ -z "$canonical_digest" || -z "$resolved_digest" ]]; then
  echo "[FAIL] unable to normalize ForgeSec image digests" >&2
  exit 2
fi

if [[ "$resolved_digest" != "$canonical_digest" ]]; then
  echo "[FAIL] ForgeSec canonical image digest mismatch" >&2
  echo "[FAIL] manifest=$canonical_ref" >&2
  echo "[FAIL] registry=registry.threadforge.local:30500/forgesec@${resolved_digest}" >&2
  exit 2
fi

if [[ "$FORGESEC_VERIFY_BUILD_DETERMINISM" == "1" ]]; then
  build_and_get_digest() {
    local tag="$1"
    SOURCE_DATE_EPOCH="$FORGESEC_SOURCE_DATE_EPOCH" docker buildx build \
      --builder "$FORGESEC_BUILDER" \
      --platform linux/arm64 \
      --no-cache \
      --pull \
      --provenance=false \
      --sbom=false \
      --output "type=image,name=registry.threadforge.local:30500/forgesec:${tag},push=true,rewrite-timestamp=true" \
      -f "$REPO_ROOT/platform/images/forgesec/Dockerfile.forgesec" \
      "$REPO_ROOT/platform/images/forgesec" >/dev/null
    skopeo inspect --tls-verify=true --cert-dir "$REGISTRY_CERT_DIR" --creds "${THREADFORGE_REGISTRY_USER}:${THREADFORGE_REGISTRY_PASSWORD}" --format '{{.Digest}}' "docker://registry.threadforge.local:30500/forgesec:${tag}"
  }

  d1="$(build_and_get_digest det-check-a)"
  d2="$(build_and_get_digest det-check-b)"
  if [[ "$d1" != "$d2" ]]; then
    echo "[FAIL] NON_DETERMINISTIC_BUILD" >&2
    echo "[FAIL] digest1=$d1" >&2
    echo "[FAIL] digest2=$d2" >&2
    exit 2
  fi
fi

# Enforce build/push -> sign -> verify -> deploy ordering for ForgeSec.
"$REPO_ROOT/scripts/supply_chain/sign_images.sh" --mode sign --image "$canonical_ref" >/dev/null
"$REPO_ROOT/scripts/supply_chain/sign_images.sh" --mode verify --image "$canonical_ref" >/dev/null
printf '%s\n' "$canonical_ref"
