#!/usr/bin/env bash
set -euo pipefail

resolve_registry_ipv4() {
  local container_name="$1"
  local registry_ipv4=""

  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi

  registry_ipv4="$(
    docker inspect "${container_name}" \
      --format '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' 2>/dev/null || true
  )"
  if [[ -z "${registry_ipv4}" ]]; then
    registry_ipv4="$(
      docker inspect "${container_name}" \
        --format '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' 2>/dev/null \
        | awk 'NF { print; exit }' || true
    )"
  fi

  [[ -n "${registry_ipv4}" ]] || return 1
  printf '%s\n' "${registry_ipv4}"
}

