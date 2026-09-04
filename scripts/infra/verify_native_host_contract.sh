#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REGISTRY_CONTAINER="${REGISTRY_CONTAINER:-threadforge-registry}"
REGISTRY_HOSTPORT="${REGISTRY_HOSTPORT:-registry.threadforge.local:30500}"
REGISTRY_USER="${THREADFORGE_REGISTRY_USER:-threadforge}"
REGISTRY_PASSWORD="${THREADFORGE_REGISTRY_PASSWORD:-threadforge-dev-password}"
REGISTRY_CA="${REPO_ROOT}/certs/threadforge-ingress-ca.crt"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-registry.threadforge.local:30500/kindest-node@sha256:48321fb2717f92527d9aba9a9b32055dff622f9c356ea3de2f1ffb75344f87bf}"

fail() {
  echo "[FAIL] NATIVE_HOST_CONTRACT: $*" >&2
  exit 2
}

[[ -f "$REGISTRY_CA" ]] || fail "registry CA missing: $REGISTRY_CA"
docker inspect "$REGISTRY_CONTAINER" >/dev/null 2>&1 || fail "registry container missing: $REGISTRY_CONTAINER"
[[ "$(docker inspect -f '{{.State.Running}}' "$REGISTRY_CONTAINER" 2>/dev/null)" == "true" ]] \
  || fail "registry container is not running: $REGISTRY_CONTAINER"

cert_dir="$(mktemp -d)"
trap 'rm -rf "$cert_dir"' EXIT
cp "$REGISTRY_CA" "$cert_dir/ca.crt"
skopeo inspect \
  --creds "${REGISTRY_USER}:${REGISTRY_PASSWORD}" \
  --tls-verify=true \
  --cert-dir "$cert_dir" \
  "docker://${KIND_NODE_IMAGE}" >/dev/null \
  || fail "canonical kind node image is unavailable from $REGISTRY_HOSTPORT"

bash "$REPO_ROOT/scripts/infra/host_trust_prime.sh" --mode verify
echo "[PASS] native host contract: Docker registry, CA, trust, and kind node image are ready"
