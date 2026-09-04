#!/usr/bin/env bash
set -uo pipefail

observability_audit() {
  infer_root

  local status="PASS"
  local observability_dir="false"
  local grafana_found="false"
  local prometheus_found="false"
  local cluster_reachable="false"

  [[ -d "$REPO_ROOT/platform/deploy/infra/observability" ]] && observability_dir="true"
  if command -v rg >/dev/null 2>&1; then
    rg -q "grafana" "$REPO_ROOT/platform/deploy/infra/observability" >/dev/null 2>&1 && grafana_found="true"
    rg -q "prometheus" "$REPO_ROOT/platform/deploy/infra/observability" >/dev/null 2>&1 && prometheus_found="true"
  else
    grep -R -q "grafana" "$REPO_ROOT/platform/deploy/infra/observability" >/dev/null 2>&1 && grafana_found="true"
    grep -R -q "prometheus" "$REPO_ROOT/platform/deploy/infra/observability" >/dev/null 2>&1 && prometheus_found="true"
  fi

  if [[ "$observability_dir" != "true" ]]; then
    status="WARN"
    echo "Observability manifests missing"
  else
    echo "Observability manifests present"
  fi

  if need_cmd kubectl && kubectl get ns >/dev/null 2>&1; then
    cluster_reachable="true"
    echo "Live cluster reachable for optional observability checks"
  else
    echo "Live cluster unavailable; observability live checks skipped"
  fi

  AUDIT_PHASE_STATUS="$status"
  write_phase_json "observability" "Observability Wiring" "$status" "{\"observability_dir_present\": $(json_bool "$observability_dir"), \"grafana_manifest_found\": $(json_bool "$grafana_found"), \"prometheus_manifest_found\": $(json_bool "$prometheus_found"), \"cluster_reachable\": $(json_bool "$cluster_reachable")}"
}
