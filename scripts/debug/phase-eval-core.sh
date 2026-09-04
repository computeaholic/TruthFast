#!/usr/bin/env bash
# phase-eval-core.sh - Core logic for phase evaluation, pure functions for unit testing
# Usage: source this file and call evaluate_phase <workload> <declared_class> <st_json> <pod_json> <endpoints_tempo_json> <endpoints_minio_json> <exporter_status>

evaluate_phase() {
  local workload="$1"; shift
  local declared_class="$1"; shift
  local st_json="$1"; shift
  local pod_json="$1"; shift
  local endpoints_tempo_json="$1"; shift
  local endpoints_minio_json="$1"; shift
  local exporter_status="$1"; shift || true

  local has_startup has_readiness has_liveness has_endpoints minio_ready ready_status

  has_startup=$(echo "$st_json" | jq -r '[.spec.template.spec.containers[]? | has("startupProbe")] | any') || has_startup="false"
  has_readiness=$(echo "$st_json" | jq -r '[.spec.template.spec.containers[]? | has("readinessProbe")] | any') || has_readiness="false"
  has_liveness=$(echo "$st_json" | jq -r '[.spec.template.spec.containers[]? | has("livenessProbe")] | any') || has_liveness="false"
  has_endpoints=$(echo "$endpoints_tempo_json" | jq -r '.subsets? | length > 0') || has_endpoints="false"
  minio_ready=$(echo "$endpoints_minio_json" | jq -r '.items[]? | select(.metadata.name=="minio") | .subsets? | length > 0') || minio_ready="false"
  ready_status=$(echo "$pod_json" | jq -r '.status.conditions[]? | select(.type=="Ready") | .status // ""') || ready_status=""

  local phase="UNKNOWN" reason=""
  if [ "$declared_class" != "dependency-gated" ]; then
    phase="UNGATED"; reason="not dependency-gated"
  else
    # presence of pod_json indicates pod exists; readiness indicates init
    if [ -z "$pod_json" ] || [ -z "$ready_status" ]; then
      phase="CREATED"; reason="pod not yet initialised"
    else
      if [ "$has_startup" != "true" ]; then
        phase="STARTING"; reason="startupProbe missing or not configured"
      fi
      if [ "$has_startup" = "true" ] && [ "$minio_ready" != "true" ]; then
        phase="DEPENDENCIES_PENDING"; reason="MinIO endpoints not ready"
      fi
      if [ "$ready_status" = "True" ]; then
        if [ "$has_readiness" = "true" ] && [ "$has_endpoints" = "true" ]; then
          phase="SERVING"; reason="pod Ready and service endpoints present"
        else
          phase="READY"; reason="pod Ready but readiness probe or endpoints missing"
        fi
      fi
      if [ "$exporter_status" = "live" ]; then
        phase="DEGRADED"; reason="live exporter errors detected"
      fi
    fi
  fi

  echo "phase=$phase"; echo "reason=$reason"; echo "has_startup=$has_startup"; echo "has_readiness=$has_readiness"; echo "has_liveness=$has_liveness"; echo "has_endpoints=$has_endpoints"; echo "minio_ready=$minio_ready"; echo "ready_status=$ready_status"
}
