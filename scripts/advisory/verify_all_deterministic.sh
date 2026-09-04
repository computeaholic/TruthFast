#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_DIR="artifacts"
RUNS_DIR="${ARTIFACT_DIR}/runs"
NORMALIZED_RUNS_DIR="${RUNS_DIR}/normalized"
TIMELINE_LOG="${ARTIFACT_DIR}/verify_timeline.log"
STATE_BEFORE_FILE="${ARTIFACT_DIR}/state_before.json"
STATE_AFTER_FILE="${ARTIFACT_DIR}/state_after.json"
RUN_COUNT=3
MAX_RETRIES=3
BACKOFFS=(1 2 4)

mkdir -p "${ARTIFACT_DIR}"
mkdir -p "${RUNS_DIR}" "${NORMALIZED_RUNS_DIR}"
: > "${TIMELINE_LOG}"

log_timeline() {
  local stage="$1"
  local event="$2"
  local run_id="$3"
  local attempt="$4"
  local exit_code="$5"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf '%s\tstage=%s\tevent=%s\trun=%s\tattempt=%s\texit=%s\n' \
    "${ts}" "${stage}" "${event}" "${run_id}" "${attempt}" "${exit_code}" >> "${TIMELINE_LOG}"
}

capture_state() {
  local out_file="$1"
  local pod_count_all
  local namespace_count
  local restart_sum
  local authz_policy_count

  pod_count_all="$(kubectl get pods -A --no-headers 2>/dev/null | wc -l | awk '{print $1}')"
  namespace_count="$(kubectl get ns --no-headers 2>/dev/null | wc -l | awk '{print $1}')"
  restart_sum="$(kubectl get pods -A -o json 2>/dev/null | jq '[.items[] | .status.containerStatuses[]?.restartCount] | add // 0')"
  authz_policy_count="$(kubectl get authorizationpolicy -A --no-headers 2>/dev/null | wc -l | awk '{print $1}')"

  jq -n \
    --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson pod_count_all "${pod_count_all}" \
    --argjson namespace_count "${namespace_count}" \
    --argjson restart_sum "${restart_sum}" \
    --argjson authz_policy_count "${authz_policy_count}" \
    '{
      timestamp: $timestamp,
      pod_count_all: $pod_count_all,
      namespace_count: $namespace_count,
      restart_sum: $restart_sum,
      authz_policy_count: $authz_policy_count
    }' > "${out_file}"

  jq empty "${out_file}" >/dev/null
}

compare_state() {
  local before_file="$1"
  local after_file="$2"

  local before_pods after_pods
  local before_restarts after_restarts
  local before_policies after_policies
  local before_ns after_ns

  before_pods="$(jq -r '.pod_count_all' "${before_file}")"
  after_pods="$(jq -r '.pod_count_all' "${after_file}")"
  before_restarts="$(jq -r '.restart_sum' "${before_file}")"
  after_restarts="$(jq -r '.restart_sum' "${after_file}")"
  before_policies="$(jq -r '.authz_policy_count' "${before_file}")"
  after_policies="$(jq -r '.authz_policy_count' "${after_file}")"
  before_ns="$(jq -r '.namespace_count' "${before_file}")"
  after_ns="$(jq -r '.namespace_count' "${after_file}")"

  if [[ "${before_pods}" != "${after_pods}" ]]; then
    echo "[FAIL] Unexpected pod-count drift: before=${before_pods}, after=${after_pods}"
    return 1
  fi

  if [[ "${before_restarts}" != "${after_restarts}" ]]; then
    echo "[FAIL] Unexpected restart-count drift: before=${before_restarts}, after=${after_restarts}"
    return 1
  fi

  if [[ "${before_policies}" != "${after_policies}" ]]; then
    echo "[FAIL] Unexpected AuthorizationPolicy count drift: before=${before_policies}, after=${after_policies}"
    return 1
  fi

  if [[ "${before_ns}" != "${after_ns}" ]]; then
    echo "[FAIL] Unexpected namespace-count drift: before=${before_ns}, after=${after_ns}"
    return 1
  fi

  if kubectl get ns agents-rogue >/dev/null 2>&1; then
    echo "[FAIL] Namespace churn detected: agents-rogue still exists"
    return 1
  fi

  return 0
}

wait_istio_synced() {
  local timeout=180
  local elapsed=0

  while (( elapsed < timeout )); do
    if kubectl get ns istio-system >/dev/null 2>&1; then
      local raw
      raw="$(istioctl proxy-status 2>/dev/null || true)"

      if [[ -n "${raw}" ]]; then
        if ! echo "${raw}" | grep -E 'NOT SENT|STALE' >/dev/null 2>&1; then
          # Istio CLI output differs by version:
          # - Some versions include CDS/LDS/EDS/RDS SYNCED columns.
          # - Others show only NAME/CLUSTER/ISTIOD/VERSION/SUBSCRIBED TYPES.
          # In both cases, absence of STALE/NOT SENT indicates healthy sync.
          if echo "${raw}" | grep -q 'SYNCED'; then
            local unsynced
            unsynced="$(echo "${raw}" | awk 'NR>1 && NF>0 {bad=0; for (i=2; i<=5 && i<=NF; i++) { if ($i != "SYNCED") bad=1 } if (bad==1) print $0 }')"
            if [[ -z "${unsynced}" ]]; then
              return 0
            fi
          else
            local rows
            rows="$(echo "${raw}" | awk 'NR>1 && NF>0 {c++} END {print c+0}')"
            if (( rows > 0 )); then
              return 0
            fi
          fi
        fi
      fi
    fi

    sleep 3
    elapsed=$((elapsed + 3))
  done

  echo "[FAIL] Istio proxies not fully SYNCED after ${timeout}s"
  istioctl proxy-status 2>/dev/null || true
  return 1
}

wait_pods_ready() {
  local timeout=180

  kubectl wait --for=condition=Ready pod --all -n istio-system --timeout="${timeout}s" >/dev/null
  kubectl wait --for=condition=Ready pod --all -n spire-system --timeout="${timeout}s" >/dev/null
  kubectl wait --for=condition=Ready pod --all -n agents-lab --timeout="${timeout}s" >/dev/null
}

get_spire_restart_sum() {
  kubectl get pods -n spire-system -o json 2>/dev/null \
    | jq '[.items[] | .status.containerStatuses[]?.restartCount] | add // 0'
}

wait_spire_stable() {
  local timeout=180
  local elapsed=0

  while (( elapsed < timeout )); do
    local rs1 rs2

    kubectl wait --for=condition=Ready pod --all -n spire-system --timeout=30s >/dev/null || true

    rs1="$(get_spire_restart_sum)"
    sleep 5
    rs2="$(get_spire_restart_sum)"

    if [[ "${rs1}" == "${rs2}" ]]; then
      local agent_logs
      agent_logs="$(kubectl logs -n spire-system -l app=spire-agent --tail=200 2>/dev/null || true)"
      if ! echo "${agent_logs}" | grep -Eqi 'failed to fetch bundle|unable to connect|x509|certificate signed by unknown authority|failed to attest|panic:|fatal'; then
        return 0
      fi
    fi

    sleep 3
    elapsed=$((elapsed + 8))
  done

  echo "[FAIL] SPIRE did not converge to a stable connected state"
  return 1
}

wait_for_convergence() {
  local stage_name="$1"
  echo "[GATE] Waiting for convergence before stage: ${stage_name}"
  wait_pods_ready
  wait_istio_synced
  wait_spire_stable
  echo "[GATE] Convergence ready for stage: ${stage_name}"
}

is_transient_failure() {
  local log_file="$1"

  # Logic failures are not transient and must not be retried.
  if grep -E '^\[FAIL\]|\[FAIL\]' "${log_file}" >/dev/null 2>&1; then
    return 1
  fi

  # Most scripts emit explicit [FAIL] for deterministic logic failures.
  # If a command exits non-zero without [FAIL], treat it as transient
  # control-plane/convergence instability and allow bounded retries.
  return 0
}

run_with_timeline() {
  local stage_name="$1"
  local run_id="$2"
  local attempt="$3"
  local cmd="$4"
  local log_file="$5"

  log_timeline "${stage_name}" "start" "${run_id}" "${attempt}" "-"
  set +e
  bash -lc "${cmd}" >"${log_file}" 2>&1
  local code=$?
  set -e
  log_timeline "${stage_name}" "end" "${run_id}" "${attempt}" "${code}"

  cat "${log_file}"
  return "${code}"
}

run_stage_with_retry() {
  local stage_name="$1"
  local run_id="$2"
  local cmd="$3"

  local attempt=1
  while (( attempt <= MAX_RETRIES )); do
    wait_for_convergence "${stage_name}"

    local log_file
    log_file="${ARTIFACT_DIR}/stage_${run_id}_${stage_name}_attempt${attempt}.log"

    if run_with_timeline "${stage_name}" "${run_id}" "${attempt}" "${cmd}" "${log_file}"; then
      return 0
    fi

    if ! is_transient_failure "${log_file}"; then
      echo "[FAIL] ${stage_name} failed with non-transient error on attempt ${attempt}"
      return 1
    fi

    if (( attempt == MAX_RETRIES )); then
      echo "[FAIL] ${stage_name} transient failure persisted after ${MAX_RETRIES} attempts"
      return 1
    fi

    local backoff
    backoff="${BACKOFFS[$((attempt - 1))]}"
    echo "[WARN] ${stage_name} transient failure; retrying in ${backoff}s (attempt ${attempt}/${MAX_RETRIES})"
    sleep "${backoff}"
    attempt=$((attempt + 1))
  done
}

run_stage_once() {
  local stage_name="$1"
  local run_id="$2"
  local cmd="$3"

  local log_file
  log_file="${ARTIFACT_DIR}/stage_${run_id}_${stage_name}.log"
  run_with_timeline "${stage_name}" "${run_id}" "1" "${cmd}" "${log_file}"
}

collect_run_artifacts() {
  local run_id="$1"
  local run_dir="${RUNS_DIR}/run${run_id}"

  rm -rf "${run_dir}"
  mkdir -p "${run_dir}"

  local required=(
    "enforcement.json"
    "enforcement_adversarial.json"
    "network_bypass.json"
    "cross_namespace.json"
    "sidecar_bypass.json"
    "identity_spoof.json"
    "chaos_spire.json"
    "chaos_istio.json"
    "spire_status.json"
    "spire_trust_mismatch.json"
    "state_before.json"
    "state_after.json"
  )

  local f
  for f in "${required[@]}"; do
    if [[ ! -f "${ARTIFACT_DIR}/${f}" ]]; then
      echo "[FAIL] Missing artifact for run ${run_id}: ${ARTIFACT_DIR}/${f}"
      return 1
    fi
    cp "${ARTIFACT_DIR}/${f}" "${run_dir}/${f}"
  done
}

normalize_json_file() {
  local src="$1"
  local dst="$2"

  jq '
    del(.timestamp) |
    del(.policy_propagation_seconds) |
    del(.propagation_times) |
    del(.max) |
    del(.min) |
    del(.avg)
  ' "${src}" > "${dst}"
}

normalize_run_dir() {
  local run_id="$1"
  local src_dir="${RUNS_DIR}/run${run_id}"
  local dst_dir="${NORMALIZED_RUNS_DIR}/run${run_id}"

  rm -rf "${dst_dir}"
  mkdir -p "${dst_dir}"

  local f
  for f in "${src_dir}"/*.json; do
    local base
    base="$(basename "${f}")"
    normalize_json_file "${f}" "${dst_dir}/${base}"
  done
}

compare_runs() {
  local run_a="$1"
  local run_b="$2"

  normalize_run_dir "${run_a}"
  normalize_run_dir "${run_b}"

  if ! diff -ru "${NORMALIZED_RUNS_DIR}/run${run_a}" "${NORMALIZED_RUNS_DIR}/run${run_b}" > "${ARTIFACT_DIR}/artifacts_diff_run${run_a}_run${run_b}.txt"; then
    echo "[FAIL] Artifact drift detected between run ${run_a} and run ${run_b}"
    return 1
  fi

  echo "[PASS] Artifacts identical between run ${run_a} and run ${run_b} (allowed timing fields excluded)"
  return 0
}

run_pipeline_once() {
  local run_id="$1"

  echo "[VERIFY-DET] Starting run ${run_id}/${RUN_COUNT}"

  run_stage_once "deploy_lab" "${run_id}" "bash scripts/deploy_lab.sh"
  run_stage_once "spire_trust_mismatch" "${run_id}" "bash scripts/test_spire_trust_mismatch.sh"
  run_stage_once "validate_spire" "${run_id}" "bash scripts/advisory/validate_spire.sh"

  # Snapshot immediately before deterministic enforcement/chaos sequence.
  capture_state "${STATE_BEFORE_FILE}"

  run_stage_with_retry "enforcement" "${run_id}" "bash scripts/advisory/verify_enforcement.sh"
  run_stage_with_retry "adversarial" "${run_id}" "bash scripts/advisory/validate_enforcement_adversarial.sh"
  run_stage_with_retry "network_bypass" "${run_id}" "bash scripts/advisory/validate_network_bypass.sh"
  run_stage_with_retry "cross_namespace" "${run_id}" "bash scripts/advisory/validate_cross_namespace.sh"

  # Chaos stage is isolated as one ordered block.
  run_stage_with_retry "chaos" "${run_id}" "bash scripts/test_sidecar_bypass.sh && bash scripts/test_identity_spoof.sh && bash scripts/test_spire_failure.sh && bash scripts/test_istio_failure.sh"

  capture_state "${STATE_AFTER_FILE}"
  compare_state "${STATE_BEFORE_FILE}" "${STATE_AFTER_FILE}"

  run_stage_once "capture_evidence" "${run_id}" "TF_SKIP_VERIFY=1 bash scripts/capture_evidence.sh"
  collect_run_artifacts "${run_id}"

  echo "[VERIFY-DET] Run ${run_id}/${RUN_COUNT} completed"
}

main() {
  local run_id
  for run_id in $(seq 1 "${RUN_COUNT}"); do
    run_pipeline_once "${run_id}"

    if (( run_id > 1 )); then
      local prev
      prev=$((run_id - 1))
      compare_runs "${prev}" "${run_id}"
    fi
  done

  echo "[PASS] verify-all determinism hardening checks passed across ${RUN_COUNT} consecutive runs"
}

main "$@"
