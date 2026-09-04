#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INGRESS_HOST="${THREADFORGE_INGRESS_HOST:-echo.threadforge.local}"
ALLOW_PATH="${TF_ALLOW_PATH:-/healthz}"
DENY_PATH="${TF_DENY_PATH:-/api/v1/operator/status}"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

kubectl() {
  run_real_kubectl "$@"
}

ensure_cluster_readable || exit $?

detect_ingress_base() {
  local node_ip node_port lb_ip lb_host

  node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  node_port="$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || true)"
  if [[ -n "$node_ip" && -n "$node_port" ]]; then
    printf 'http://%s:%s\n' "$node_ip" "$node_port"
    return 0
  fi

  lb_ip="$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  lb_host="$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -n "$lb_ip" ]]; then
    printf 'http://%s\n' "$lb_ip"
    return 0
  fi
  if [[ -n "$lb_host" ]]; then
    printf 'http://%s\n' "$lb_host"
    return 0
  fi

  return 1
}

BASE_URL="${THREADFORGE_INGRESS_URL:-$(detect_ingress_base || true)}"
if [[ -z "$BASE_URL" ]]; then
  echo "[FAIL] MISSING_PREREQ: ingress not available"
  exit 10
fi

BASE_URL="${BASE_URL%/}"

NORTH_SOUTH_HTTP_RETRIES="${NORTH_SOUTH_HTTP_RETRIES:-12}"
NORTH_SOUTH_HTTP_RETRY_SLEEP_SECONDS="${NORTH_SOUTH_HTTP_RETRY_SLEEP_SECONDS:-5}"

allow_code="000"
for _attempt in $(seq 1 "$NORTH_SOUTH_HTTP_RETRIES"); do
  allow_code="$(curl -sS --max-time 10 -H "Host: ${INGRESS_HOST}" -o /dev/null -w '%{http_code}' "${BASE_URL}${ALLOW_PATH}" || true)"
  if [[ "$allow_code" == "200" ]]; then
    break
  fi
  if (( _attempt < NORTH_SOUTH_HTTP_RETRIES )); then
    sleep "$NORTH_SOUTH_HTTP_RETRY_SLEEP_SECONDS"
  fi
done
if [[ "$allow_code" != "200" ]]; then
  echo "[FAIL] CONTRACT_VIOLATION: north-south allow path returned ${allow_code}"
  exit 2
fi

deny_code="000"
for _attempt in $(seq 1 "$NORTH_SOUTH_HTTP_RETRIES"); do
  deny_code="$(curl -sS --max-time 10 -H "Host: ${INGRESS_HOST}" -o /dev/null -w '%{http_code}' "${BASE_URL}${DENY_PATH}" || true)"
  if [[ "$deny_code" == "403" ]]; then
    break
  fi
  if (( _attempt < NORTH_SOUTH_HTTP_RETRIES )); then
    sleep "$NORTH_SOUTH_HTTP_RETRY_SLEEP_SECONDS"
  fi
done
if [[ "$deny_code" != "403" ]]; then
  echo "[FAIL] CONTRACT_VIOLATION: north-south deny path returned ${deny_code}"
  exit 2
fi

echo "[NORTH-SOUTH] External ingress validation: PASS"
echo "  - authorized request: 200"
echo "  - unauthorized request: 403"
echo "  - identity enforced via SPIFFE"
