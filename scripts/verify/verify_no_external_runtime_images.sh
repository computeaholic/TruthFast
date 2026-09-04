#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PIN_MAP_PATH="${PIN_MAP_PATH:-$REPO_ROOT/platform/config/image_pin_map.json}"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

kubectl() {
  run_real_kubectl "$@"
}

# =============================================================================
# verify_no_external_runtime_images.sh — ThreadForge runtime image enforcement
#
# Enforces that ALL running pods use:
#   1. Images from the internal registry only (not docker.io, quay.io, etc.)
#   2. Digest-pinned images only (sha256: suffix)
#
# This is enforcement, not detection — exits 1 on any violation.
# Exit code: 0 = all images trusted + pinned, 1 = any violation found
# =============================================================================

NAMESPACE_RE='^(threadforge($|-)|threadforge-test$|threadforge-lab$|observability$|istio-system$|spire-system$|argocd$|minio$|tempo$|loki$|cert-manager$)'

VIOLATIONS=0
VIOLATION_LIST=()

fail_image() {
  local reason="$1"
  local image="$2"
  echo "[FAIL] $reason: $image"
  VIOLATIONS=$(( VIOLATIONS + 1 ))
  VIOLATION_LIST+=("$reason: $image")
}

# Internal registry allowlist pattern — set TF_INTERNAL_REGISTRY to override
INTERNAL_REGISTRY="${TF_INTERNAL_REGISTRY:-registry\.threadforge\.local|threadforge:30500|localhost|127\.0\.0\.1|kind-registry}"
declare -A APPROVED_TAG_ALIASES=()

ensure_cluster_readable || exit $?

if [ ! -f "$PIN_MAP_PATH" ]; then
  echo "[FAIL] image pin map missing: $PIN_MAP_PATH"
  exit 10
fi

while IFS= read -r alias_ref; do
  [ -n "$alias_ref" ] || continue
  APPROVED_TAG_ALIASES["$alias_ref"]=1
done < <(python3 - <<'PY' "$PIN_MAP_PATH"
import json
import pathlib
import sys

pin_map = json.loads(pathlib.Path(sys.argv[1]).read_text())
for key in pin_map.keys():
    print(key)
PY
)

echo "[runtime-images] Collecting all pod images from cluster..."

# Build a list of images from running pods in enforcement namespaces.
tmp_ns="$(mktemp)"
trap 'rm -f "$tmp_ns"' EXIT

kubectl get ns --no-headers 2>/dev/null | awk '{print $1}' | grep -E "$NAMESPACE_RE" > "$tmp_ns" || true

ALL_IMAGES=""
while IFS= read -r ns; do
  [ -n "$ns" ] || continue
  ALL_IMAGES+="$(kubectl get pods -n "$ns" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.ephemeralContainers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null || true)"
  ALL_IMAGES+=$'\n'
done < "$tmp_ns"

if [ -z "$ALL_IMAGES" ]; then
  echo "[FAIL] no running pod images found — cannot prove runtime image policy"
  exit 2
fi

# Also get image IDs (actual running digest) from running pod status in enforcement namespaces.
RUNNING_IMAGE_IDS=""
while IFS= read -r ns; do
  [ -n "$ns" ] || continue
  RUNNING_IMAGE_IDS+="$(kubectl get pods -n "$ns" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.imageID}{"\n"}{end}{range .status.initContainerStatuses[*]}{.imageID}{"\n"}{end}{range .status.ephemeralContainerStatuses[*]}{.imageID}{"\n"}{end}{end}' 2>/dev/null || true)"
  RUNNING_IMAGE_IDS+=$'\n'
done < "$tmp_ns"

echo "[runtime-images] Checking image spec entries..."

while IFS= read -r image; do
  [ -z "$image" ] && continue

  # ---- Check 1: must be digest pinned (contain @sha256:) or resolve via the approved pin map ----
  if [[ "$image" != *"@sha256:"* ]] && [[ -z "${APPROVED_TAG_ALIASES[$image]:-}" ]]; then
    fail_image "not digest-pinned" "$image"
  fi

  # ---- Check 2: must come from an allowed registry ----
  # Extract registry prefix after removing any digest suffix.
  image_base="${image%@*}"
  image_base="${image_base%%:*}"  # strip tag
  registry=$(echo "$image_base" | cut -d'/' -f1)

  # If registry looks like a hostname (contains dot or colon, or is localhost)
  # then check against allowlist; otherwise it's a short docker.io image
  if [[ "$registry" == *"."* ]] || [[ "$registry" == *":"* ]] || [[ "$registry" == "localhost" ]]; then
    if ! echo "$registry" | grep -qE "($INTERNAL_REGISTRY)"; then
      fail_image "external registry not allowed" "$image"
    fi
  else
    # Short image  = implicit docker.io — external by definition
    fail_image "implicit docker.io image (external)" "$image"
  fi

done <<< "$ALL_IMAGES"

# ---- Check 3: running imageIDs must also be sha256-pinned ----
echo "[runtime-images] Checking running imageID digests..."
while IFS= read -r imageid; do
  [ -z "$imageid" ] && continue
  if [[ "$imageid" != *"sha256:"* ]]; then
    fail_image "running imageID not sha256-pinned" "$imageid"
  fi
done <<< "$RUNNING_IMAGE_IDS"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "[runtime-images] Violations found: $VIOLATIONS"
if [ "$VIOLATIONS" -gt 0 ]; then
  echo "[FAIL] runtime image enforcement FAILED:"
  for v in "${VIOLATION_LIST[@]}"; do echo "  [FAIL] $v"; done
  exit 2
fi
echo "[PASS] all runtime images are digest-pinned and from allowed registries"
exit 0
