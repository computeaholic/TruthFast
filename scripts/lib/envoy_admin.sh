#!/usr/bin/env bash

# Capture the Envoy SDS view without relying on istioctl port-forwarding.
capture_envoy_secrets() {
  local namespace="$1"
  local pod="$2"
  local output_path="$3"
  local raw_path
  raw_path="$(mktemp)"
  rm -f "$output_path"

  if ! "${KUBECTL_BIN:?KUBECTL_BIN must be set}" -n "$namespace" exec "$pod" -c istio-proxy -- \
    curl -fsS --max-time 10 http://127.0.0.1:15000/config_dump >"$raw_path"; then
    rm -f "$raw_path"
    return 1
  fi

  if ! python3 - "$raw_path" "$output_path" <<'PY'
import json
import pathlib
import sys

raw_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
dump = json.loads(raw_path.read_text(encoding="utf-8"))
configs = dump.get("configs")
if not isinstance(configs, list):
    raise SystemExit("Envoy config dump returned no configs")
secrets = next(
    (
        item
        for item in configs
        if isinstance(item, dict) and str(item.get("@type", "")).endswith("SecretsConfigDump")
    ),
    None,
)
if not isinstance(secrets, dict):
    raise SystemExit("Envoy config dump has no SecretsConfigDump")
dynamic = secrets.get("dynamic_active_secrets")
if dynamic is None:
    dynamic = secrets.get("dynamicActiveSecrets")
static = secrets.get("static_secrets")
if static is None:
    static = secrets.get("staticSecrets")
if not isinstance(dynamic, list) or not dynamic:
    raise SystemExit("Envoy config dump has no dynamic active secrets")


def snake_to_camel(value: str) -> str:
    head, *tail = value.split("_")
    return head + "".join(part[:1].upper() + part[1:] for part in tail)


def camelize(value):
    if isinstance(value, dict):
        return {snake_to_camel(str(key)): camelize(item) for key, item in value.items()}
    if isinstance(value, list):
        return [camelize(item) for item in value]
    return value


output_path.write_text(
    json.dumps(
        {
            "dynamicActiveSecrets": camelize(dynamic),
            "staticSecrets": camelize(static or []),
        }
    )
    + "\n",
    encoding="utf-8",
)
PY
  then
    rm -f "$raw_path"
    return 1
  fi
  rm -f "$raw_path"
}

# Capture the active certificate view from the same proxy-local admin surface.
capture_envoy_certs() {
  local namespace="$1"
  local pod="$2"
  local output_path="$3"
  local raw_path
  raw_path="$(mktemp)"
  rm -f "$output_path"

  if ! "${KUBECTL_BIN:?KUBECTL_BIN must be set}" -n "$namespace" exec "$pod" -c istio-proxy -- \
    curl -fsS --max-time 10 http://127.0.0.1:15000/certs >"$raw_path"; then
    rm -f "$raw_path"
    return 1
  fi
  mv "$raw_path" "$output_path"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  KUBECTL_BIN="${KUBECTL_BIN:-$(type -P kubectl || true)}"
  if [[ -z "$KUBECTL_BIN" ]]; then
    echo "[FAIL] Envoy observer UNOBSERVABLE: kubectl not found" >&2
    exit 2
  fi

  case "${1:-}" in
    capture-secrets)
      [[ $# -eq 4 ]] || { echo "usage: $0 capture-secrets <namespace> <pod> <output>" >&2; exit 2; }
      capture_envoy_secrets "$2" "$3" "$4"
      ;;
    capture-certs)
      [[ $# -eq 4 ]] || { echo "usage: $0 capture-certs <namespace> <pod> <output>" >&2; exit 2; }
      capture_envoy_certs "$2" "$3" "$4"
      ;;
    *)
      echo "usage: $0 {capture-secrets|capture-certs} <namespace> <pod> <output>" >&2
      exit 2
      ;;
  esac
fi
