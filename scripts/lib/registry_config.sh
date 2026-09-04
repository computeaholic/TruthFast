#!/usr/bin/env bash

# Shared local/CI registry configuration contract.  The registry container
# must never be recreated from an unparsed or partially written config.
registry_config_validate() {
  local config_path="$1"
  local certs_dir="$2"
  local registry_port="$3"

  [[ -s "$config_path" ]] || return 1
  [[ -d "$certs_dir" ]] || return 1

  python3 - "$config_path" "$certs_dir" "$registry_port" <<'PY'
import pathlib
import sys

import yaml

config_path = pathlib.Path(sys.argv[1])
certs_dir = pathlib.Path(sys.argv[2])
registry_port = sys.argv[3]


def reject(message: str) -> None:
    print(f"[registry-config] invalid: {message}", file=sys.stderr)
    raise SystemExit(1)


try:
    document = yaml.safe_load(config_path.read_text(encoding="utf-8"))
except (OSError, yaml.YAMLError) as exc:
    reject(f"YAML parse failed: {exc}")

if not isinstance(document, dict):
    reject("top-level document is not a mapping")
if document.get("version") != 0.1:
    reject("version must be 0.1")

storage = document.get("storage")
if not isinstance(storage, dict):
    reject("storage section is missing")
filesystem = storage.get("filesystem")
if not isinstance(filesystem, dict) or filesystem.get("rootdirectory") != "/var/lib/registry":
    reject("storage.filesystem.rootdirectory must be /var/lib/registry")

http = document.get("http")
if not isinstance(http, dict):
    reject("http section is missing")
if http.get("addr") != f":{registry_port}":
    reject(f"http.addr must be :{registry_port}")

tls = http.get("tls")
if not isinstance(tls, dict):
    reject("http.tls section is missing")
expected_paths = {
    "certificate": ("/certs/registry.crt", "registry.crt"),
    "key": ("/certs/registry.key", "registry.key"),
}
for field, (expected_path, filename) in expected_paths.items():
    if tls.get(field) != expected_path:
        reject(f"http.tls.{field} must be {expected_path}")
    if not (certs_dir / filename).is_file():
        reject(f"TLS material is missing: {certs_dir / filename}")

print("REGISTRY_CONFIG_VALID=true")
PY
}

registry_config_write() {
  local destination="$1"
  local certs_dir="$2"
  local registry_port="$3"
  local temporary_path

  temporary_path="$(mktemp "${destination}.tmp.XXXXXX")" || return 1
  if ! cat >"$temporary_path" <<REGCFG
version: 0.1
log:
  fields:
    service: registry
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/registry
  delete:
    enabled: true
http:
  addr: :${registry_port}
  tls:
    certificate: /certs/registry.crt
    key: /certs/registry.key
  headers:
    X-Content-Type-Options: [nosniff]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
REGCFG
  then
    rm -f "$temporary_path"
    return 1
  fi

  if ! registry_config_validate "$temporary_path" "$certs_dir" "$registry_port" >/dev/null; then
    rm -f "$temporary_path"
    return 1
  fi
  chmod 0644 "$temporary_path" || {
    rm -f "$temporary_path"
    return 1
  }
  if ! mv -f "$temporary_path" "$destination"; then
    rm -f "$temporary_path"
    return 1
  fi
}
