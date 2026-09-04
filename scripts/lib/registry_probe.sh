#!/usr/bin/env bash

registry_probe_reconcile_host_dns() {
  local host="$1"
  local container="${2:-threadforge-registry}"
  local registry_ip hosts_file tmp_file

  registry_ip="$(docker inspect "$container" \
    --format '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' 2>/dev/null || true)"
  if [[ ! "$registry_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "[FAIL] unable to resolve current registry IP for ${container}" >&2
    return 1
  fi

  hosts_file="${REGISTRY_HOSTS_FILE:-/etc/hosts}"
  if [[ -w "$hosts_file" && -w "$(dirname "$hosts_file")" ]]; then
    tmp_file="$(mktemp "$(dirname "$hosts_file")/hosts.XXXXXX")"
    awk -v host="$host" -v ip="$registry_ip" '
      $0 !~ "(^|[[:space:]])" host "([[:space:]]|$)" { print }
      END { print ip " " host }
    ' "$hosts_file" >"$tmp_file"
    chmod --reference="$hosts_file" "$tmp_file" 2>/dev/null || true
    mv "$tmp_file" "$hosts_file"
    return 0
  fi

  # Desktop runners commonly expose /etc/hosts as a protected file. Docker is
  # already the owner of this local registry topology, so use a root utility
  # container only to apply the same dynamic mapping in that host file.
  docker run --rm --user 0 \
    --mount "type=bind,src=${hosts_file},dst=/threadforge-hosts" \
    alpine:3.19 sh -ec '
      host="$1"
      ip="$2"
      grep -Ev "[[:space:]]${host}([[:space:]]|$)" /threadforge-hosts > /threadforge-hosts.tmp || true
      printf "%s %s\\n" "$ip" "$host" >> /threadforge-hosts.tmp
      cat /threadforge-hosts.tmp > /threadforge-hosts
      rm -f /threadforge-hosts.tmp
    ' -- "$host" "$registry_ip"
}

registry_probe_resolve() {
  local host="$1"
  local port="$2"
  printf '%s:%s:127.0.0.1' "$host" "$port"
}

registry_probe_anonymous_status() {
  local host="$1"
  local port="$2"
  curl --resolve "$(registry_probe_resolve "$host" "$port")" \
    -ksS -o /dev/null -w '%{http_code}' "https://${host}:${port}/v2/" || true
}

registry_probe_authenticated_status() {
  local host="$1"
  local port="$2"
  local user="$3"
  local password="$4"
  curl --resolve "$(registry_probe_resolve "$host" "$port")" \
    -ksS -u "${user}:${password}" -o /dev/null -w '%{http_code}' \
    "https://${host}:${port}/v2/" || true
}
