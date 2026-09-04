#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

FORGESEC_NAMESPACE="${FORGESEC_NAMESPACE:-forgesec}"
OBSERVABILITY_NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability}"
KYVERNO_NAMESPACE="${KYVERNO_NAMESPACE:-kyverno}"
TIMEOUT_SECONDS="${DETERMINISM_SETTLE_TIMEOUT_SECONDS:-120}"
POLL_SECONDS="${DETERMINISM_SETTLE_POLL_SECONDS:-2}"

deadline=$((SECONDS + TIMEOUT_SECONDS))

count_resources() {
  local kind="$1"
  kubectl get "$kind" -n "$FORGESEC_NAMESPACE" -l app=forgesec --no-headers 2>/dev/null | wc -l | tr -d ' '
}

service_has_ready_endpoints() {
  local service="$1"
  local addresses
  addresses="$(kubectl get endpoints "$service" -n "$OBSERVABILITY_NAMESPACE" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null || true)"
  [[ -n "$addresses" ]]
}

kyverno_has_no_active_transients() {
  local active_jobs active_cleanup_pods
  active_jobs="$(
    kubectl get jobs -n "$KYVERNO_NAMESPACE" -o json 2>/dev/null \
      | jq -r '.items[]? | select((.status.active // 0) > 0) | .metadata.name' \
      || true
  )"
  active_cleanup_pods="$(
    kubectl get pods -n "$KYVERNO_NAMESPACE" -o json 2>/dev/null \
      | jq -r '.items[]?
        | select((.metadata.name // "") | startswith("kyverno-cleanup-"))
        | select(any((.metadata.ownerReferences // [])[]?; .kind == "Job"))
        | select((.status.phase // "") == "Running" or (.status.phase // "") == "Pending")
        | .metadata.name' \
      || true
  )"
  [[ -z "$active_jobs" && -z "$active_cleanup_pods" ]]
}

has_ready_serviceaccount_pod() {
  local namespace="$1"
  local service_account="$2"
  local rows
  rows="$(kubectl get pods -n "$namespace" -o jsonpath='{range .items[*]}{.spec.serviceAccountName}{"\t"}{.status.phase}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null || true)"
  printf '%s\n' "$rows" | grep -q "^${service_account}[[:space:]]\+Running[[:space:]]\+True$"
}

bash "$REPO_ROOT/scripts/verify/wait_for_system_ready.sh" >/dev/null

while (( SECONDS < deadline )); do
  bash "$REPO_ROOT/scripts/verify/wait_for_system_ready.sh" >/dev/null

  jobs_remaining="$(count_resources jobs)"
  pods_remaining="$(count_resources pods)"

  if [[ "${jobs_remaining:-0}" == "0" && "${pods_remaining:-0}" == "0" ]] \
    && service_has_ready_endpoints prometheus \
    && service_has_ready_endpoints loki \
    && service_has_ready_endpoints tempo \
    && service_has_ready_endpoints grafana \
    && has_ready_serviceaccount_pod "$OBSERVABILITY_NAMESPACE" tempo-sa \
    && kyverno_has_no_active_transients; then
    echo "[PASS] determinism settle complete: ForgeSec transient resources cleared and system readiness is ready"
    exit 0
  fi

  sleep "$POLL_SECONDS"
done

echo "[FAIL] CLEANUP_TIMEOUT: ForgeSec transient resources did not clear deterministically"
exit 2
