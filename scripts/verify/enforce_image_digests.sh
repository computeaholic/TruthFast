#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

# =============================================================================
# enforce_image_digests.sh — repository manifest image policy enforcement
#
# Enforces that Kubernetes manifest image references are:
#   1) Internal-registry hosted
#   2) Digest-pinned (@sha256:...)
#
# Scope is intentionally limited to manifest roots (default: infra deploy gitops)
# to avoid false positives in archived evidence and helper snippets.
# =============================================================================

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCAN_ROOTS="${IMAGE_POLICY_SCAN_ROOTS:-platform/deploy}"

# ThreadForge policy: internal registry only.
ALLOWED_REGISTRY_RE='^registry\.threadforge\.local:30500$'

FAILURES=0

fail_line() {
  local file="$1"
  local line_no="$2"
  local msg="$3"
  echo "[FAIL] ${file}:${line_no} ${msg}"
  FAILURES=$((FAILURES + 1))
}

if ! command -v rg >/dev/null 2>&1; then
  echo "[FAIL] ripgrep (rg) is required for manifest policy enforcement"
  exit 10
fi

echo "[image-policy] roots=${SCAN_ROOTS}"

for root in $SCAN_ROOTS; do
  if [ ! -d "$ROOT/$root" ]; then
    continue
  fi

  while IFS=: read -r file line_no line; do
    [ -z "$file" ] && continue

    img="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*image:[[:space:]]*([^[:space:]]+).*/\1/')"
    img="${img%\"}"
    img="${img#\"}"
    img="${img%\'}"
    img="${img#\'}"

    # Skip template placeholders and unresolved substitutions.
    if [[ "$img" == *"{{"* ]] || [[ "$img" == *"}}"* ]] || [[ "$img" == *'${'* ]]; then
      continue
    fi

    # Not an image token after parsing.
    if [[ -z "$img" ]] || [[ "$img" == "image:" ]]; then
      continue
    fi

    image_ref_no_digest="${img%@sha256:*}"
    image_registry="${image_ref_no_digest%%/*}"

    # Explicitly fail if the registry host is external.
    if [[ "$image_registry" =~ (^|\.)docker\.io$|(^|\.)quay\.io$|(^|\.)ghcr\.io$ ]]; then
      fail_line "$file" "$line_no" "external registry host forbidden: $img"
      continue
    fi

    if ! [[ "$image_registry" =~ $ALLOWED_REGISTRY_RE ]]; then
      fail_line "$file" "$line_no" "external or untrusted registry image: $img"
      continue
    fi

    if [[ ! "$img" =~ @sha256:[a-f0-9]{64}$ ]]; then
      fail_line "$file" "$line_no" "image is not digest-pinned: $img"
      continue
    fi

    # Reject mixed tag+digest references (repo:tag@sha256:...).
    image_repo_part="${image_ref_no_digest##*/}"
    if [[ "$image_repo_part" == *:* ]]; then
      fail_line "$file" "$line_no" "tag-based image reference is forbidden: $img"
      continue
    fi
  done < <(rg -n --no-heading --glob '*.yaml' --glob '*.yml' '^[[:space:]]*image:[[:space:]]*\S+' "$ROOT/$root" || true)
done

if [ "$FAILURES" -gt 0 ]; then
  echo "[FAIL] manifest image policy violations: $FAILURES"
  exit 2
fi

echo "[PASS] manifest image policy enforced (internal + digest-pinned)"
exit 0
