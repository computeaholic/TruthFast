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

require_service_endpoints() {
  local namespace="$1"
  local service="$2"

  kubectl get service "$service" -n "$namespace" >/dev/null 2>&1 || {
    echo "[FAIL] missing service ${namespace}/${service}"
    return 2
  }

  kubectl get endpoints "$service" -n "$namespace" -o jsonpath='{.subsets}' 2>/dev/null | grep -q . || {
    echo "[FAIL] service ${namespace}/${service} has no endpoints"
    return 2
  }
}

reject_stale_references() {
  local pattern="$1"
  shift
  if rg -n "$pattern" "$@" >/dev/null 2>&1; then
    echo "[FAIL] stale topology reference matched pattern $pattern"
    rg -n "$pattern" "$@"
    return 2
  fi
}

ensure_cluster_readable

require_service_endpoints threadforge-system threadforge-notifier
require_service_endpoints threadforge-system postgres
require_service_endpoints threadforge-system clickhouse
require_service_endpoints minio minio
require_service_endpoints observability grafana
require_service_endpoints observability tempo

authoritative_files=(
  "$REPO_ROOT/scripts/infra/bootstrap.sh"
  "$REPO_ROOT/scripts/prove_system.sh"
  "$REPO_ROOT/scripts/make/forgesec.mk"
  "$REPO_ROOT/platform/images/forgesec/Dockerfile.forgesec"
  "$REPO_ROOT/platform/deploy/forgesec/identity-job.yaml"
  "$REPO_ROOT/platform/deploy/forgesec/surface-job.yaml"
  "$REPO_ROOT/platform/deploy/infra/observability/forgesec-continuity-check-cronjob.yaml"
)

reject_stale_references 'threadforge-api(\.|:|\b)' "${authoritative_files[@]}"
reject_stale_references 'registry\.threadforge\.svc(\.cluster\.local)?' "${authoritative_files[@]}"

echo "[PASS] authoritative service topology matches the live bootstrap surface"
