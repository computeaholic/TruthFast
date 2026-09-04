#!/usr/bin/env bash
# doctor-phase-eval.sh - Advisory-only phase evaluation for dependency-gated workloads (Tempo example)
# - Implements a minimal phase model and evaluates Tempo's current phase using probes, readiness, endpoints, and dependency checks
# - Supports identity-scoped overrides via annotations (read-only) and a repo-local authorization mapping
# - Outputs advisory messages only

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "⚠️  'jq' not found; skipping phase evaluation (requires jq)."
  exit 0
fi

AUTHZ_FILE="${AUTHZ_FILE:-scripts/phase-authorizations.yaml}"
WINDOW_MINUTES=${WINDOW_MINUTES:-10}

# Minimal phase enum
# CREATED -> STARTING -> DEPENDENCIES_PENDING -> READY -> SERVING
#             \__________________________/
# DEGRADED
# FROZEN (manual hold)

# Helper: read annotation
get_annotation() {
  local res=$1; shift
  local key=$1; shift
  kubectl get $res -o json -n tempo 2>/dev/null | jq -r ".metadata.annotations[\"$key\"] // empty"
}

echo "🔎 Running phase evaluation (Tempo) — advisory-only"

# Check resource existence (StatefulSet 'tempo')
# For tests, prefer fixture if present to avoid relying on kubectl
if [ -n "${TEST_CASE:-}" ] && [ -f "tests/fixtures/${TEST_CASE}/statefulset-tempo.json" ]; then
  : # fixture present; proceed
elif ! kubectl get statefulset tempo -n tempo >/dev/null 2>&1; then
  echo "⚠️  Tempo StatefulSet not found in namespace 'tempo'"
  exit 0
fi

# Determine class (dependency-gated?)
# For tests, allow loading a synthetic statefulset from tests/fixtures when TEST_CASE is set
if [ -n "${TEST_CASE:-}" ] && [ -f "tests/fixtures/${TEST_CASE}/statefulset-tempo.json" ]; then
  st_json=$(cat "tests/fixtures/${TEST_CASE}/statefulset-tempo.json")
else
  st_json=$(kubectl -n tempo get statefulset tempo -o json 2>/dev/null || true)
fi

declared_class=$(echo "$st_json" | jq -r '.metadata.labels["threadforge.io/workload-class"] // ""')
if [ -z "$declared_class" ]; then
  # fall back to allowlist by name or existence: if the StatefulSet exists and its name matches known dependency-gated workloads, classify as dependency-gated
  if kubectl -n tempo get statefulset tempo >/dev/null 2>&1; then
    declared_class="dependency-gated"
  fi
fi

# Gather signals
pod=$(kubectl -n tempo get pods -l statefulset.kubernetes.io/pod-name=tempo-0 --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true)
if [ -z "$pod" ]; then
  # try direct pod name
  pod="tempo-0"
fi

# Pod readiness (use JSON parsing to avoid jsonpath quoting issues)
# For tests, allow loading synthetic pod JSON from fixtures
if [ -n "${TEST_CASE:-}" ] && [ -f "tests/fixtures/${TEST_CASE}/pod-tempo-0.json" ]; then
  pod_json=$(cat "tests/fixtures/${TEST_CASE}/pod-tempo-0.json")
else
  pod_json=$(kubectl -n tempo get pod "$pod" -o json 2>/dev/null || true)
fi
ready_cond_ts=$(echo "$pod_json" | jq -r '.status.conditions[]? | select(.type=="Ready") | .lastTransitionTime // ""')
ready_status=$(echo "$pod_json" | jq -r '.status.conditions[]? | select(.type=="Ready") | .status // ""')

# Probe presence
has_startup=$(kubectl -n tempo get statefulset tempo -o json | jq -r '.spec.template.spec.containers[]? | has("startupProbe")' | grep -q true && echo true || echo false)
has_readiness=$(kubectl -n tempo get statefulset tempo -o json | jq -r '.spec.template.spec.containers[]? | has("readinessProbe")' | grep -q true && echo true || echo false)
has_liveness=$(kubectl -n tempo get statefulset tempo -o json | jq -r '.spec.template.spec.containers[]? | has("livenessProbe")' | grep -q true && echo true || echo false)

# Service endpoints
svc_ep=$(kubectl -n tempo get endpoints tempo -o json 2>/dev/null || true)
has_endpoints=$(echo "$svc_ep" | jq -r '.subsets? | length > 0' || echo false)

# Dependency check: MinIO endpoints presence
minio_eps=$(kubectl -n minio get endpoints -o json 2>/dev/null || true)
minio_ready=$(echo "$minio_eps" | jq -r '.items[]? | select(.metadata.name=="minio") | .subsets? | length > 0' || echo false)

# Collector error classification reuse: call helper script but capture its output
collector_errors_out=$(scripts/doctor-dependency-lint.sh 2>/dev/null || true)
# Determine if live exporter errors exist by searching that output
if echo "$collector_errors_out" | grep -q "Live exporter connection failures detected"; then
  exporter_status="live"
elif echo "$collector_errors_out" | grep -q "historic, pre-restart"; then
  exporter_status="historic"
else
  exporter_status="none"
fi

# Determine derived phase (use core evaluator if available for testability)
phase="UNKNOWN"; reason=""

if [ -f "scripts/phase-eval-core.sh" ]; then
  # prepare inputs
  # Use previously loaded fixture-backed JSON where present, otherwise fetch via kubectl
  if [ -z "${st_json:-}" ] || [ "$st_json" = "" ]; then
    st_json=$(kubectl -n tempo get statefulset tempo -o json 2>/dev/null || true)
  fi
  if [ -z "${pod_json:-}" ] || [ "$pod_json" = "" ]; then
    pod_json=$(kubectl -n tempo get pod "$pod" -o json 2>/dev/null || true)
  fi
  if [ -z "${endpoints_tempo_json:-}" ] || [ "$endpoints_tempo_json" = "" ]; then
    endpoints_tempo_json=$(kubectl -n tempo get endpoints tempo -o json 2>/dev/null || true)
  fi
  if [ -z "${endpoints_minio_json:-}" ] || [ "$endpoints_minio_json" = "" ]; then
    endpoints_minio_json=$(kubectl -n minio get endpoints -o json 2>/dev/null || true)
  fi
  # exporter_status retained from earlier collector errors capture (no change)
  exporter_status="$exporter_status"

  # shellcheck source=/dev/null
  source scripts/phase-eval-core.sh
  eval_out=$(evaluate_phase "Tempo" "$declared_class" "$st_json" "$pod_json" "$endpoints_tempo_json" "$endpoints_minio_json" "$exporter_status")
  phase=$(echo "$eval_out" | awk -F= '/phase/ {print $2}')
  reason=$(echo "$eval_out" | awk -F= '/reason/ {print $2}')
  has_startup=$(echo "$eval_out" | awk -F= '/has_startup/ {print $2}')
  has_readiness=$(echo "$eval_out" | awk -F= '/has_readiness/ {print $2}')
  has_liveness=$(echo "$eval_out" | awk -F= '/has_liveness/ {print $2}')
  has_endpoints=$(echo "$eval_out" | awk -F= '/has_endpoints/ {print $2}')
  minio_ready=$(echo "$eval_out" | awk -F= '/minio_ready/ {print $2}')
  ready_status=$(echo "$eval_out" | awk -F= '/ready_status/ {print $2}')
else
  # fallback (original logic)
  if [ "$declared_class" != "dependency-gated" ]; then
    phase="UNGATED"
    reason="not dependency-gated"
  else
    # dependency-gated path
    if [ -z "$pod" ] || kubectl -n tempo get pod $pod >/dev/null 2>&1 && [ -z "$ready_status" ]; then
      phase="CREATED"
      reason="pod not yet initialised"
    else
      # If startupProbe exists and pod not Ready -> STARTING or DEPENDENCIES_PENDING
      if [ "$has_startup" != "true" ]; then
        phase="STARTING"
        reason="startupProbe missing or not configured"
      fi

      # If startupProbe present but endpoints for dependencies unmet -> DEPENDENCIES_PENDING
      if [ "$has_startup" = "true" ] && [ "$minio_ready" != "true" ]; then
        phase="DEPENDENCIES_PENDING"
        reason="MinIO endpoints not ready"
      fi

      # If pod is Ready and readinessProbe present and service has endpoints, mark READY/SERVING
      if [ "$ready_status" = "True" ]; then
        if [ "$has_readiness" = "true" ] && [ "$has_endpoints" = "true" ]; then
          phase="SERVING"
          reason="pod Ready and service endpoints present"
        else
          phase="READY"
          reason="pod Ready but readiness probe or endpoints missing"
        fi
      fi

      # Detect degraded conditions
      if [ "$exporter_status" = "live" ]; then
        phase="DEGRADED"
        reason="live exporter errors detected"
      fi
    fi
  fi
fi

# Detect a manual freeze override via annotation (read-only)
override_phase=$(echo "$st_json" | jq -r '.metadata.annotations["threadforge.io/phase-override"] // ""')
override_by=$(echo "$st_json" | jq -r '.metadata.annotations["threadforge.io/phase-override-identity"] // ""')

# Helper: check SPIFFE authorization in AUTHZ_FILE (deterministic, fixture-friendly)
# Returns: "authorized", "unauthorized", "no-policy", or "unauthorized-phase"
is_spiffe_authorized() {
  local spiffe="$1"; local workload="$2"; local phase="$3"; local authf="$4"
  if [ ! -f "$authf" ]; then
    echo "no-policy"; return
  fi

  # 1) exact workload block
  if grep -qE "^${workload}:" "$authf"; then
    awk -v key="${workload}:" 'BEGIN{p=0} $0 ~ "^"key""{p=1; next} p && $0 ~ "^[^[:space:]]"{exit} p{print}' "$authf" > /tmp/.auth_block 2>/dev/null || true
    if [ -s /tmp/.auth_block ]; then
      if grep -qF "$spiffe" /tmp/.auth_block; then
        if grep -q "allowed_phases:" /tmp/.auth_block >/dev/null 2>&1; then
          if grep -q " - ${phase}" /tmp/.auth_block; then
            echo "authorized"; return
          else
            echo "unauthorized-phase"; return
          fi
        else
          echo "authorized"; return
        fi
      fi
    fi
  fi

  # 2) namespace block: key is 'namespace:<name>'
  ns=$(echo "$st_json" | jq -r '.metadata.namespace // ""')
  if [ -n "$ns" ] && grep -qE "^namespace:${ns}:" "$authf"; then
    awk -v key="namespace:${ns}:" 'BEGIN{p=0} $0 ~ "^"key""{p=1; next} p && $0 ~ "^[^[:space:]]"{exit} p{print}' "$authf" > /tmp/.auth_block 2>/dev/null || true
    if [ -s /tmp/.auth_block ]; then
      if grep -qF "$spiffe" /tmp/.auth_block; then
        if grep -q "allowed_phases:" /tmp/.auth_block >/dev/null 2>&1; then
          if grep -q " - ${phase}" /tmp/.auth_block; then
            echo "authorized"; return
          else
            echo "unauthorized-phase"; return
          fi
        else
          echo "authorized"; return
        fi
      fi
    fi
  fi

  # 3) global authorized_principals list
  if grep -qE "^authorized_principals:" "$authf"; then
    awk 'BEGIN{p=0} $0 ~ "^authorized_principals:"{p=1; next} p && $0 ~ "^[^[:space:]]"{exit} p{print}' "$authf" > /tmp/.auth_block 2>/dev/null || true
    if [ -s /tmp/.auth_block ] && grep -qF "$spiffe" /tmp/.auth_block; then
      echo "authorized"; return
    fi
  fi

  echo "unauthorized"
}

# Read authorizations (repo-local)
can_override="no-policy"
# If an override is requested but no identity was supplied, surface a specific advisory
if [ -n "$override_phase" ] && [ -z "$override_by" ]; then
  can_override="no-identity"
elif [ -n "$override_by" ]; then
  can_override=$(is_spiffe_authorized "$override_by" "$(echo "$st_json" | jq -r '.metadata.name // ""')" "$override_phase" "$AUTHZ_FILE")
fi

# Output advisory
echo "workload: Tempo (namespace: tempo)"
echo "  declared_class: $declared_class"
echo "  detected_phase: $phase"
echo "  reason: $reason"
echo "  startupProbe: $has_startup, readinessProbe: $has_readiness, livenessProbe: $has_liveness"
echo "  service_endpoints_present: $has_endpoints"
echo "  minio_ready: $minio_ready"
echo "  exporter_errors: $exporter_status"

if [ -n "$override_phase" ]; then
  echo "⚠️  Manual phase override present: desired='$override_phase' by='$override_by' (authorization: $can_override)"
  case "$can_override" in
    authorized)
      echo "ℹ️  override identity is authorized to request this phase change (advisory only)"
      ;;
    unauthorized)
      echo "⚠️  override identity is NOT authorized per local policy (advisory only)"
      ;;
    unauthorized-phase)
      echo "⚠️  override identity is present but NOT authorized for requested phase '$override_phase' on this workload (advisory only)"
      ;;
    no-policy)
      echo "ℹ️  override identity presence detected but no local authorization policy file found"
      ;;
    no-identity)
      echo "⚠️  override identity not supplied (no identity supplied)"
      ;;
  esac
fi

# Advancement policy (repo-local override): annotation 'threadforge.io/advancement-policy' default permissive
adv_policy=$(echo "$st_json" | jq -r '.metadata.annotations["threadforge.io/advancement-policy"] // "permissive"')
# Determine whether phase itself permits advancement (simple heuristic)
if [ "$phase" = "DEPENDENCIES_PENDING" ] || [ "$phase" = "DEGRADED" ]; then
  phase_permits=false
else
  phase_permits=true
fi
# Evaluate policy: strict means only allow when phase permits; permissive allows regardless
if [ "$adv_policy" = "strict" ]; then
  if [ "$phase_permits" = "true" ]; then
    policy_permits=true
  else
    policy_permits=false
  fi
else
  policy_permits=true
fi

# Output both phase and policy perspectives
echo "  phase_permits_advancement: $phase_permits"
echo "  advancement_policy: $adv_policy (permits_advancement: $policy_permits)"

# Call out mismatches between phase and policy
if [ "$phase_permits" = "false" ] && [ "$policy_permits" = "true" ]; then
  echo "⚠️  Phase insufficient but advancement policy permissive — phase blocks advancement but policy allows it (advisory only)"
elif [ "$phase_permits" = "true" ] && [ "$policy_permits" = "false" ]; then
  echo "⚠️  Phase permits advancement but advancement policy prevents it — action required to align policy (advisory only)"
else
  if [ "$policy_permits" = "true" ]; then
    echo "ℹ️  Phase and advancement policy both permit advancement"
  else
    echo "ℹ️  Phase and advancement policy both prevent advancement"
  fi
fi

exit 0
