#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

sync_one() {
  local src="$1"
  local dst="$2"
  local tmp

  mkdir -p "$(dirname "${dst}")"
  tmp="$(mktemp)"
  trap 'rm -f "${tmp}"' RETURN

  {
    echo "# GENERATED FROM ${src#${ROOT}/} — DO NOT EDIT"
    echo
    cat "${src}"
  } >"${tmp}"

  if [[ -f "${dst}" ]] && cmp -s "${tmp}" "${dst}"; then
    rm -f "${tmp}"
    trap - RETURN
    return 0
  fi

  mv "${tmp}" "${dst}"
  trap - RETURN
}

sync_one \
  "${ROOT}/platform/deploy/base/policy/vap-enforce-internal-registry-digest.yaml" \
  "${ROOT}/platform/deploy/gitops/infra/policy/vap-enforce-internal-registry-digest.yaml"

sync_one \
  "${ROOT}/platform/deploy/base/policy/kyverno-require-image-digests.yaml" \
  "${ROOT}/platform/deploy/gitops/infra/policy/kyverno-require-image-digests.yaml"
