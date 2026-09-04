#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

kubectl() {
  run_real_kubectl "$@"
}

require_namespace_label() {
  local namespace="$1"
  local key="$2"
  local expected="$3"
  local namespace_json actual

  namespace_json="$(kubectl get namespace "$namespace" -o json)" || {
    echo "[FAIL] unable to read namespace ${namespace}"
    return 2
  }

  actual="$(printf '%s' "$namespace_json" | LABEL_KEY_ENV="$key" python3 -c '
import json
import os
import sys

doc = json.load(sys.stdin)
print(doc.get("metadata", {}).get("labels", {}).get(os.environ["LABEL_KEY_ENV"], ""), end="")
')"
  if [[ "$actual" != "$expected" ]]; then
    echo "[FAIL] namespace ${namespace} label ${key}=${actual:-<missing>} expected ${expected}"
    return 2
  fi
}

require_strict_peerauth() {
  local namespace="$1"
  local result

  result="$(kubectl get peerauthentication -n "$namespace" -o json)" || {
    echo "[FAIL] unable to read PeerAuthentication resources in namespace $namespace"
    return 2
  }

  printf '%s' "$result" | PEERAUTH_NAMESPACE_ENV="$namespace" python3 -c '
import json
import os
import sys

namespace = os.environ["PEERAUTH_NAMESPACE_ENV"]
doc = json.load(sys.stdin)
items = doc.get("items", [])
if not items:
    raise SystemExit(2)

for item in items:
    mode = item.get("spec", {}).get("mtls", {}).get("mode", "UNSET")
    if mode != "STRICT":
        raise SystemExit(2)
'
}

require_sidecar() {
  local namespace="$1"
  local selector="$2"
  local pod_json

  pod_json="$(kubectl get pod -n "$namespace" -l "$selector" -o json)" || {
    echo "[FAIL] unable to list pods for ${namespace} selector ${selector}"
    return 2
  }

  printf '%s' "$pod_json" | SIDECAR_NAMESPACE_ENV="$namespace" SIDECAR_SELECTOR_ENV="$selector" python3 -c '
import json
import os
import sys

namespace = os.environ["SIDECAR_NAMESPACE_ENV"]
selector = os.environ["SIDECAR_SELECTOR_ENV"]
doc = json.load(sys.stdin)
items = doc.get("items", [])
running = [item for item in items if item.get("status", {}).get("phase") == "Running"]
if not running:
    raise SystemExit(2)

for item in running:
    names = {container.get("name") for container in item.get("spec", {}).get("containers", [])}
    if "istio-proxy" not in names:
        raise SystemExit(2)
'
}

ensure_cluster_readable

require_namespace_label threadforge-system istio-injection enabled
require_namespace_label observability istio-injection enabled

require_strict_peerauth threadforge-system
require_strict_peerauth spire-system

require_sidecar threadforge-system app=threadforge-notifier
require_sidecar threadforge-system app=postgres
require_sidecar threadforge-system app=clickhouse
require_sidecar minio app=minio
require_sidecar observability app=grafana
require_sidecar observability app=tempo

echo "[PASS] namespace injection, STRICT PeerAuthentication, and sidecar baseline verified"
