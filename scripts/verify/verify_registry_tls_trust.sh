#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REGISTRY_HOST="${REGISTRY_HOST:-registry.threadforge.local}"
REGISTRY_PORT="${REGISTRY_PORT:-30500}"
REGISTRY_CA_KEY="${REGISTRY_CA_KEY:-threadforge-ingress-ca.crt}"
PROBE_NAMESPACE="${REGISTRY_TRUST_PROBE_NAMESPACE:-threadforge-system}"
PROBE_SELECTOR="${REGISTRY_TRUST_PROBE_SELECTOR:-app=threadforge-notifier}"
PROBE_CONTAINER="${REGISTRY_TRUST_PROBE_CONTAINER:-registry-trust-probe}"
PROBE_MOUNT_PATH="${REGISTRY_TRUST_PROBE_MOUNT_PATH:-/etc/registry-ca/threadforge-ingress-ca.crt}"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

kubectl() {
  run_real_kubectl "$@"
}

require_configmap_key() {
  local namespace="$1"
  local configmap_json

  configmap_json="$(kubectl get configmap registry-ca -n "$namespace" -o json)" || {
    echo "[FAIL] missing configmap registry-ca in namespace $namespace"
    return 2
  }

  printf '%s' "$configmap_json" | REGISTRY_CA_KEY_ENV="$REGISTRY_CA_KEY" python3 -c '
import json
import os
import sys

doc = json.load(sys.stdin)
key = os.environ["REGISTRY_CA_KEY_ENV"]
data = doc.get("data", {})
if key not in data or not data[key].strip():
    raise SystemExit(2)
'
}

require_probe_mount() {
  local deployment_json
  deployment_json="$(kubectl get deployment threadforge-notifier -n "$PROBE_NAMESPACE" -o json)" || {
    echo "[FAIL] missing deployment threadforge-notifier in namespace $PROBE_NAMESPACE"
    return 2
  }

  printf '%s' "$deployment_json" | PROBE_CONTAINER_ENV="$PROBE_CONTAINER" PROBE_MOUNT_PATH_ENV="$PROBE_MOUNT_PATH" python3 -c '
import json
import os
import sys

doc = json.load(sys.stdin)
container_name = os.environ["PROBE_CONTAINER_ENV"]
mount_path = os.environ["PROBE_MOUNT_PATH_ENV"]
template = doc.get("spec", {}).get("template", {}).get("spec", {})
volumes = {volume.get("name"): volume for volume in template.get("volumes", []) if isinstance(volume, dict)}

for container in template.get("containers", []):
    if container.get("name") != container_name:
        continue
    mounts = {mount.get("name"): mount for mount in container.get("volumeMounts", []) if isinstance(mount, dict)}
    mount = mounts.get("registry-ca")
    volume = volumes.get("registry-ca")
    if mount and mount.get("mountPath") == "/etc/registry-ca" and volume and volume.get("configMap", {}).get("name") == "registry-ca":
        raise SystemExit(0)
raise SystemExit(2)
  '
}

run_registry_probe() {
  local probe_pod http_code

  probe_pod="$(kubectl get pod -n "$PROBE_NAMESPACE" -l "$PROBE_SELECTOR" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
  if [[ -z "$probe_pod" ]]; then
    echo "[FAIL] no running registry trust probe pod found for selector $PROBE_SELECTOR"
    return 2
  fi

  http_code="$(kubectl exec -n "$PROBE_NAMESPACE" "$probe_pod" -c "$PROBE_CONTAINER" -- \
    sh -c "test -s '$PROBE_MOUNT_PATH' && curl -sS --cacert '$PROBE_MOUNT_PATH' -o /dev/null -w '%{http_code}' 'https://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/'")"

  case "$http_code" in
    200|401)
      echo "[PASS] live registry TLS verified from ${PROBE_NAMESPACE}/${probe_pod}:${PROBE_CONTAINER}"
      ;;
    *)
      echo "[FAIL] registry TLS probe returned unexpected status ${http_code}"
      return 2
      ;;
  esac
}

ensure_cluster_readable
require_configmap_key threadforge-system
require_configmap_key forgesec
require_probe_mount
run_registry_probe
