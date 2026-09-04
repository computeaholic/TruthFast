#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$REPO_ROOT/artifacts/debug/echo_identity_debug.log"
SPIRE_SOCKET_PATH="/run/spire/private/spire-server.sock"
KUBECTL_BIN="$(type -P kubectl 2>/dev/null || true)"
SPIRE_SERVER_POD=""

run_kubectl() {
  "$KUBECTL_BIN" "$@"
}

if [ -z "$KUBECTL_BIN" ] || [ ! -x "$KUBECTL_BIN" ]; then
  echo "[FAIL] kubectl binary not found" >&2
  exit 2
fi

SPIRE_SERVER_POD="$(run_kubectl -n spire-system get pods -l app=spire-server -o jsonpath='{.items[0].metadata.name}')"

mkdir -p "$(dirname "$OUT")"

{
  echo "=== echo pod and service account ==="
  run_kubectl -n threadforge-test get pod -l app=echo -o wide
  run_kubectl -n threadforge-test get pod -l app=echo -o jsonpath='{range .items[*]}{.metadata.name}{" sa="}{.spec.serviceAccountName}{"\n"}{end}'
  echo

  echo "=== echo sidecar presence ==="
  run_kubectl -n threadforge-test get pod -l app=echo -o jsonpath='{range .items[*]}{.metadata.name}{" containers="}{range .spec.containers[*]}{.name}{","}{end}{"\n"}{end}'
  echo

  echo "=== echo injection labels and annotations ==="
  run_kubectl -n threadforge-test get pod -l app=echo -o yaml
  echo
  run_kubectl -n threadforge-test get ns threadforge-test -o yaml
  echo

  echo "=== SPIRE entries relevant to echo ==="
  run_kubectl -n spire-system exec "$SPIRE_SERVER_POD" -- /opt/spire/bin/spire-server entry show -output json -socketPath "$SPIRE_SOCKET_PATH"
  echo

  echo "=== echo envoy cert dump ==="
  run_kubectl -n threadforge-test exec deploy/echo -c istio-proxy -- curl -s localhost:15000/certs
  echo

  echo "=== echo envoy sidecar logs ==="
  run_kubectl -n threadforge-test logs deploy/echo -c istio-proxy --tail=200
  echo

  echo "=== echo socket visibility ==="
  run_kubectl -n threadforge-test exec deploy/echo -c istio-proxy -- ls -R /var/run || true
  echo
  run_kubectl -n threadforge-test exec deploy/echo -c istio-proxy -- ls -R /var/run/secrets || true
  echo
} > "$OUT"

echo "[debug] wrote echo identity state to $OUT"
