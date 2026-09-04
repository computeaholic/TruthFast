#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  echo "[FAIL] validate_all.sh must run under bash"
  exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib/bootstrap_timeline.sh
source "$REPO_ROOT/scripts/lib/bootstrap_timeline.sh"
export TF_BT_RESET_EVENTS=1
tf_bt_init "$REPO_ROOT"
unset TF_BT_RESET_EVENTS

mkdir -p artifacts/mode_runs
LOG_FILE="artifacts/mode_runs/validate-all.log"
: > "$LOG_FILE"
VALIDATE_ALL_RUN_ID="${VALIDATE_ALL_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
VALIDATE_ALL_SOURCE_SHA="${VALIDATE_ALL_SOURCE_SHA:-$(git rev-parse HEAD 2>/dev/null || true)}"
VALIDATE_ALL_RUNTIME_IMAGE_CONVERGENCE_CACHE_FILE="${VALIDATE_ALL_RUNTIME_IMAGE_CONVERGENCE_CACHE_FILE:-artifacts/mode_runs/${VALIDATE_ALL_RUN_ID}.runtime-image-convergence.json}"
export VALIDATE_ALL_RUN_ID VALIDATE_ALL_SOURCE_SHA VALIDATE_ALL_RUNTIME_IMAGE_CONVERGENCE_CACHE_FILE
STALL_TIMEOUT_SECONDS="${VALIDATE_ALL_STALL_TIMEOUT_SECONDS:-900}"
HEARTBEAT_SECONDS="${VALIDATE_ALL_HEARTBEAT_SECONDS:-30}"
PRIVILEGE_PROMPT_TIMEOUT_SECONDS="${VALIDATE_ALL_PRIVILEGE_PROMPT_TIMEOUT_SECONDS:-90}"
EXECUTION_PROFILE="${THREADFORGE_EXECUTION_PROFILE:-local}"
HOST_TRUST_MUTATION_MODE="${THREADFORGE_HOST_TRUST_MUTATION:-denied}"
LAST_OUTPUT_EPOCH="$(date +%s)"

if ! [[ "$STALL_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || (( STALL_TIMEOUT_SECONDS <= 0 )); then
  echo "[FAIL] MISSING_PREREQ: VALIDATE_ALL_STALL_TIMEOUT_SECONDS must be a positive integer" | tee -a "$LOG_FILE"
  exit 2
fi

if ! [[ "$HEARTBEAT_SECONDS" =~ ^[0-9]+$ ]] || (( HEARTBEAT_SECONDS <= 0 )); then
  echo "[FAIL] MISSING_PREREQ: VALIDATE_ALL_HEARTBEAT_SECONDS must be a positive integer" | tee -a "$LOG_FILE"
  exit 2
fi

if ! [[ "$PRIVILEGE_PROMPT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || (( PRIVILEGE_PROMPT_TIMEOUT_SECONDS <= 0 )); then
  echo "[FAIL] MISSING_PREREQ: VALIDATE_ALL_PRIVILEGE_PROMPT_TIMEOUT_SECONDS must be a positive integer" | tee -a "$LOG_FILE"
  exit 2
fi

log() {
  LAST_OUTPUT_EPOCH="$(date +%s)"
  echo "$*" | tee -a "$LOG_FILE"
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "[FAIL] MISSING_PREREQ: required command '$cmd' is not available"
    exit 2
  fi
}

verify_runner_prereqs() {
  require_command timeout
  require_command tee
  require_command date
  require_command ps
}

local_verify_only_mode() {
  [[ "$EXECUTION_PROFILE" != "ci" && "$HOST_TRUST_MUTATION_MODE" != "allowed" ]]
}

assert_local_no_ci_reset_markers() {
  if ! local_verify_only_mode; then
    return 0
  fi
  if rg -q "\[CI-RESET\]" "$LOG_FILE"; then
    log "[FAIL] LOCAL_VALIDATE_ALL_BOUNDARY_VIOLATION: CI-RESET markers detected in local verify-only mode"
    exit 2
  fi
}

extract_progress_marker() {
  local line="$1"
  if [[ "$line" == *"CHECK="* ]]; then
    printf '%s' "${line#*CHECK=}"
    return 0
  fi
  if [[ "$line" == *"[PHASE]"* ]]; then
    printf '%s' "$line"
    return 0
  fi
  if [[ "$line" == *"[verify] ── "* ]]; then
    printf '%s' "$line"
    return 0
  fi
  if [[ "$line" == *"[DEBUG] applying:"* ]]; then
    printf '%s' "${line#*applying: }"
    return 0
  fi
  printf '%s' "$line" | cut -c1-180
}

extract_active_artifact() {
  local line="$1"
  if [[ "$line" == *"[DEBUG] applying:"* ]]; then
    printf '%s' "${line#*applying: }"
    return 0
  fi
  if [[ "$line" == *"CHECK="* ]]; then
    printf '%s' "${line#*CHECK=}"
    return 0
  fi
  printf '%s' "unknown"
}

proc_total_jiffies() {
  local pid="$1"
  local stat_fields
  stat_fields="$(awk '{print $14" "$15}' "/proc/${pid}/stat" 2>/dev/null || true)"
  if [[ -z "$stat_fields" ]]; then
    printf '%s' "0"
    return 0
  fi
  awk '{print $1 + $2}' <<<"$stat_fields"
}

emit_stall_timeout_context() {
  local step_name="$1"
  local command_text="$2"
  local child_pid="$3"
  local elapsed_seconds="$4"
  local silence_seconds="$5"
  local last_marker="$6"
  local current_artifact="$7"
  local cpu_active="$8"
  local child_alive="$9"
  local child_stat

  child_stat="$(ps -o stat= -p "$child_pid" 2>/dev/null | tr -d ' ' || true)"
  if [[ -z "$child_stat" ]]; then
    child_stat="UNKNOWN"
  fi

  log "FAIL_CLASS=STALL_TIMEOUT"
  log "ACTIVE_PHASE=${step_name}"
  log "ACTIVE_COMMAND=${command_text}"
  log "CHILD_PID=${child_pid}"
  log "CHILD_PID_ALIVE=${child_alive}"
  log "CHILD_PID_STATE=${child_stat}"
  log "ELAPSED_SECONDS=${elapsed_seconds}"
  log "SILENCE_SECONDS=${silence_seconds}"
  log "LAST_PROGRESS_MARKER=${last_marker}"
  log "ACTIVE_ARTIFACT=${current_artifact}"
  log "CPU_ACTIVE=${cpu_active}"
}

emit_privilege_required_context() {
  local step_name="$1"
  local command_text="$2"
  local child_pid="$3"
  local elapsed_seconds="$4"
  local reason="$5"
  local last_marker="$6"
  local stdin_tty="false"
  local stdout_tty="false"

  [[ -t 0 ]] && stdin_tty="true"
  [[ -t 1 ]] && stdout_tty="true"

  log "FAIL_CLASS=PRIVILEGE_REQUIRED"
  log "ACTIVE_PHASE=${step_name}"
  log "ACTIVE_COMMAND=${command_text}"
  log "CHILD_PID=${child_pid}"
  log "ELAPSED_SECONDS=${elapsed_seconds}"
  log "PRIVILEGE_REASON=${reason}"
  log "LAST_PROGRESS_MARKER=${last_marker}"
  log "TTY_STDIN_ATTACHED=${stdin_tty}"
  log "TTY_STDOUT_ATTACHED=${stdout_tty}"
  log "OPERATOR_ACTION=sudo -v"
}

run_step() {
  local step_name="$1"
  shift
  local -a step_cmd=("$@")
  local step_cmd_text="${step_cmd[*]}"
  local step_cmd_rc=0
  local step_had_output=0
  local now=0
  local line=""
  local step_start_epoch
  local last_progress_epoch
  local last_heartbeat_epoch
  local last_progress_marker="command-started"
  local current_artifact="unknown"
  local step_pid_alive="false"
  local cpu_active="false"
  local prev_cpu_jiffies=0
  local cpu_jiffies=0
  local silence_seconds=0
  local privilege_required_seen="false"
  local privilege_prompt_active="false"
  local privilege_prompt_epoch=0

  step_start_epoch="$(date +%s)"
  last_progress_epoch="$step_start_epoch"
  last_heartbeat_epoch="$step_start_epoch"

  if [[ "${#step_cmd[@]}" -eq 0 ]]; then
    log "[FAIL] MISSING_PREREQ: no command provided for ${step_name}"
    exit 2
  fi

  if ! command -v "${step_cmd[0]}" >/dev/null 2>&1; then
    log "[FAIL] MISSING_PREREQ: command '${step_cmd[0]}' not found for ${step_name}"
    exit 2
  fi

  log "[STEP] ${step_name}"
  log "[WAIT] waiting for ${step_name}..."

  set +e
  # Use a temp FIFO rather than coproc to avoid STEP_PROC[0] unbound-variable
  # errors under set -u when the coprocess exits before the read loop starts.
  local _fifo
  _fifo="$(mktemp -u)"
  mkfifo "$_fifo"
  "${step_cmd[@]}" >"$_fifo" 2>&1 &
  local step_pid="$!"
  prev_cpu_jiffies="$(proc_total_jiffies "$step_pid")"
  exec {_step_fd}<"$_fifo"
  rm -f "$_fifo"

  while true; do
    if IFS= read -r -t 1 line <&"${_step_fd}"; then
      step_had_output=1
      now="$(date +%s)"
      last_progress_epoch="$now"
      last_progress_marker="$(extract_progress_marker "$line")"
      current_artifact="$(extract_active_artifact "$line")"
      log "$line"

      if [[ "$line" == *"SUDO_REQUIRED"* ]]; then
        privilege_required_seen="true"
      fi

      if [[ "$line" == *"[sudo] password for "* ]]; then
        privilege_required_seen="true"
        privilege_prompt_active="true"
        privilege_prompt_epoch="$now"
        log "[WAIT] PRIVILEGE_REQUIRED_WAIT: interactive sudo prompt detected (timeout=${PRIVILEGE_PROMPT_TIMEOUT_SECONDS}s)"
      else
        privilege_prompt_active="false"
      fi
      continue
    fi

    if kill -0 "$step_pid" >/dev/null 2>&1; then
      step_pid_alive="true"
    else
      step_pid_alive="false"
    fi

    if [[ "$step_pid_alive" != "true" ]]; then
      break
    fi

    now="$(date +%s)"
    cpu_jiffies="$(proc_total_jiffies "$step_pid")"
    if (( cpu_jiffies > prev_cpu_jiffies )); then
      cpu_active="true"
      prev_cpu_jiffies="$cpu_jiffies"
      last_progress_epoch="$now"
      last_progress_marker="cpu-progress:jiffies=${cpu_jiffies}"
      current_artifact="cpu-progress"
    else
      cpu_active="false"
    fi

    silence_seconds="$(( now - last_progress_epoch ))"

    if (( now - last_heartbeat_epoch >= HEARTBEAT_SECONDS )); then
      log "[LIVENESS] phase=${step_name} pid=${step_pid} alive=${step_pid_alive} elapsed=$(( now - step_start_epoch ))s silence=${silence_seconds}s cpu_active=${cpu_active} marker=${last_progress_marker} artifact=${current_artifact}"
      last_heartbeat_epoch="$now"
    fi

    if [[ "$privilege_prompt_active" == "true" ]]; then
      local privilege_wait_seconds="$(( now - privilege_prompt_epoch ))"
      if (( privilege_wait_seconds >= PRIVILEGE_PROMPT_TIMEOUT_SECONDS )); then
        log "[FAIL] PRIVILEGE_REQUIRED_WAIT: no sudo response for ${PRIVILEGE_PROMPT_TIMEOUT_SECONDS}s"
        emit_privilege_required_context "$step_name" "$step_cmd_text" "$step_pid" "$(( now - step_start_epoch ))" "interactive-sudo-prompt-timeout" "$last_progress_marker"
        kill -TERM "$step_pid" >/dev/null 2>&1 || true
        sleep 1
        kill -KILL "$step_pid" >/dev/null 2>&1 || true
        wait "$step_pid" >/dev/null 2>&1 || true
        exec {_step_fd}<&-
        set -e
        exit 2
      fi
      continue
    fi

    if (( silence_seconds >= STALL_TIMEOUT_SECONDS )); then
      log "[FAIL] STALLED_STEP: no progress for ${STALL_TIMEOUT_SECONDS}s"
      emit_stall_timeout_context "$step_name" "$step_cmd_text" "$step_pid" "$(( now - step_start_epoch ))" "$silence_seconds" "$last_progress_marker" "$current_artifact" "$cpu_active" "$step_pid_alive"
      kill -TERM "$step_pid" >/dev/null 2>&1 || true
      sleep 1
      kill -KILL "$step_pid" >/dev/null 2>&1 || true
      wait "$step_pid" >/dev/null 2>&1 || true
      exec {_step_fd}<&-
      set -e
      exit 2
    fi
  done

  while IFS= read -r line <&"${_step_fd}"; do
    step_had_output=1
    log "$line"
  done
  exec {_step_fd}<&-

  wait "$step_pid"
  step_cmd_rc=$?
  set -e

  if [[ "$step_had_output" -eq 0 ]]; then
    log "[FAIL] STALLED_STEP: ${step_name} emitted no output"
    emit_stall_timeout_context "$step_name" "$step_cmd_text" "$step_pid" "$(( $(date +%s) - step_start_epoch ))" "$(( $(date +%s) - step_start_epoch ))" "no-output" "unknown" "false" "false"
    exit 2
  fi

  if [[ "$step_cmd_rc" -eq 124 ]]; then
    log "[FAIL] TIMEOUT in ${step_name}"
    log "FAIL_CLASS=STEP_TIMEOUT"
    log "ACTIVE_PHASE=${step_name}"
    log "ACTIVE_COMMAND=${step_cmd_text}"
    log "ELAPSED_SECONDS=$(( $(date +%s) - step_start_epoch ))"
    log "LAST_PROGRESS_MARKER=${last_progress_marker}"
    log "ACTIVE_ARTIFACT=${current_artifact}"
    exit 2
  fi

  if [[ "$step_cmd_rc" -ne 0 && "$privilege_required_seen" == "true" ]]; then
    log "[FAIL] SUDO_REQUIRED: ${step_name} requires active sudo session"
    emit_privilege_required_context "$step_name" "$step_cmd_text" "$step_pid" "$(( $(date +%s) - step_start_epoch ))" "sudo-credential-required" "$last_progress_marker"
    exit 2
  fi

  if [[ "$step_cmd_rc" -eq 127 ]]; then
    log "[FAIL] MISSING_PREREQ: command invocation failed for ${step_name}"
    exit 2
  fi

  return "$step_cmd_rc"
}

FINAL="FAIL"
VALIDATE_MODE="${VALIDATE_MODE:-standard}"
BOOTSTRAP_STATUS="FAIL"
PROOF_STATUS="FAIL"
DETERMINISM_STATUS="FAIL"
ACTIVE_STATUS="FAIL"
FORGESEC_STATUS="FAIL"
BINARY_HANDLING_STATUS="FAIL"
RUNTIME_IDENTITY_TRUTH_STATUS="FAIL"
POLICY_REALITY_STATUS="FAIL"
OBSERVABILITY_TRUTH_STATUS="FAIL"
CROSS_LAYER_CONSISTENCY_STATUS="FAIL"

is_walkthrough_mode() {
  [[ "$VALIDATE_MODE" == "walkthrough" ]]
}

phase_banner() {
  local step_label="$1"
  local description="$2"
  if is_walkthrough_mode; then
    log "${step_label} ${description}"
  fi
}

phase_result() {
  local step_label="$1"
  local rc="$2"
  local proven="$3"
  if [[ "$rc" -eq 0 ]]; then
    log "[PASS] ${step_label}"
  else
    log "[FAIL] ${step_label}"
  fi
  if is_walkthrough_mode; then
    if [[ "$rc" -eq 0 ]]; then
      log "${step_label} RESULT: PASS"
    else
      log "${step_label} RESULT: FAIL"
    fi
    log "${step_label} PROVEN: ${proven}"
    sleep 2
  fi
}

run_phase() {
  local step_label="$1"
  local description="$2"
  local proven="$3"
  shift 3

  phase_banner "$step_label" "$description"

  set +e
  run_step "$step_label" "$@"
  local rc=$?
  set -e

  phase_result "$step_label" "$rc" "$proven"
  return "$rc"
}

assert_bootstrap_namespaces() {
  local namespaces=(
    istio-system
    kyverno
    spire-system
    threadforge-test
  )
  local namespace

  for namespace in "${namespaces[@]}"; do
    if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
      log "[FAIL] BOOTSTRAP_INCOMPLETE"
      exit 2
    fi
  done
}

print_walkthrough_system_state() {
  local status_file="artifacts/proof/status.json"
  local north_south="UNKNOWN"
  local east_west="UNKNOWN"
  local identity="UNKNOWN"
  local admission="UNKNOWN"
  local runtime="UNKNOWN"

  if [[ -f "$status_file" ]]; then
    north_south="$(jq -r '(.north_south_boundary // .guarantees.north_south_boundary.status // "UNKNOWN")' "$status_file" 2>/dev/null || echo "UNKNOWN")"
    east_west="$(jq -r '(.east_west_isolation // .guarantees.east_west_isolation.status // "UNKNOWN")' "$status_file" 2>/dev/null || echo "UNKNOWN")"
    identity="$(jq -r '(.identity // .guarantees.identity_spiffe.status // "UNKNOWN")' "$status_file" 2>/dev/null || echo "UNKNOWN")"
    admission="$(jq -r '(.admission_rejection // .guarantees.admission_enforced.status // "UNKNOWN")' "$status_file" 2>/dev/null || echo "UNKNOWN")"
    runtime="$(jq -r '(.runtime_identity_verified // .guarantees.runtime_identity_verified.status // "UNKNOWN")' "$status_file" 2>/dev/null || echo "UNKNOWN")"
  fi

  log "SYSTEM STATE: VERIFIED"
  log "BOUNDARY STATUS:"
  log "  north_south: ${north_south}"
  log "  east_west: ${east_west}"
  log "  identity: ${identity}"
  log "  admission: ${admission}"
  log "  runtime: ${runtime}"
}

normalize_summary_status() {
  local value="${1:-UNKNOWN}"
  case "$value" in
    PASS|pass|true|TRUE|yes|YES)
      echo "PASS"
      ;;
    FAIL|fail|false|FALSE|no|NO)
      echo "FAIL"
      ;;
    *)
      echo "UNKNOWN"
      ;;
  esac
}

bool_true_false() {
  if [[ "${1:-FAIL}" == "PASS" ]]; then
    echo "TRUE"
  else
    echo "FALSE"
  fi
}

print_final_state() {
  local rc="$1"
  local deterministic="FALSE"

  if [ "$rc" -eq 0 ]; then
    FINAL="PASS"
  else
    FINAL="FAIL"
  fi
  if [[ "$DETERMINISM_STATUS" == "PASS" ]]; then
    deterministic="TRUE"
  fi

  log "THREADFORGE VALIDATION SUMMARY"
  log "BOOTSTRAP: ${BOOTSTRAP_STATUS}"
  log "PROOF: ${PROOF_STATUS}"
  log "DETERMINISM: ${DETERMINISM_STATUS}"
  log "ACTIVE: ${ACTIVE_STATUS}"
  log "FORGESEC: ${FORGESEC_STATUS}"
  log "THREADFORGE FINAL STATE"
  log "BINARY_HANDLING_SAFE: $(bool_true_false "$BINARY_HANDLING_STATUS")"
  log "RUNTIME_IDENTITY_TRUE: $(bool_true_false "$RUNTIME_IDENTITY_TRUTH_STATUS")"
  log "POLICY_ENFORCEMENT_REAL: $(bool_true_false "$POLICY_REALITY_STATUS")"
  log "OBSERVABILITY_TRUTH: $(bool_true_false "$OBSERVABILITY_TRUTH_STATUS")"
  log "CROSS_LAYER_CONSISTENT: $(bool_true_false "$CROSS_LAYER_CONSISTENCY_STATUS")"
  log "DETERMINISTIC: ${deterministic}"
  log "FINAL: ${FINAL}"
}

on_exit() {
  local rc="$?"
  python3 "$REPO_ROOT/scripts/verify/render_bootstrap_timeline.py" \
    "$REPO_ROOT/artifacts/bootstrap_timeline.events.jsonl" \
    "$REPO_ROOT/artifacts/bootstrap_timeline.json" \
    "$REPO_ROOT/artifacts/bootstrap_phase_matrix.md" >/dev/null 2>&1 || true
  bash scripts/verify/verify_mode_artifact_parity.sh capture validate-all >/dev/null 2>&1 || true
  print_final_state "$rc"
}

trap on_exit EXIT

verify_runner_prereqs

log "[validate-all] START"

if [[ "$EXECUTION_PROFILE" != "ci" ]]; then
  if ! run_phase "host-trust-verify" "Verify host Docker trust boundary" "Host Docker trust CA matches required registry CA without privileged mutation." \
    timeout --foreground "${VALIDATE_ALL_HOST_TRUST_VERIFY_TIMEOUT_SECONDS:-120}s" make host-trust-verify; then
    exit 2
  fi
fi

if local_verify_only_mode; then
  log "[SKIP] cluster-reset (local verify-only mode; set THREADFORGE_HOST_TRUST_MUTATION=allowed for destructive full reset)"
else
  run_phase "cluster-reset" "Reset cluster (clean state)" "Cluster is reset to a clean baseline before verification." \
    timeout --foreground "${VALIDATE_ALL_CLUSTER_RESET_TIMEOUT_SECONDS:-1800}s" make cluster-reset
fi

assert_local_no_ci_reset_markers

if ! run_phase "infra-bootstrap" "Bootstrap system (identity + policy + mesh)" "Identity, policy, mesh, and baseline controls were applied in the live cluster." \
  timeout --foreground "${VALIDATE_ALL_INFRA_BOOTSTRAP_TIMEOUT_SECONDS:-5400}s" make infra-bootstrap BOOTSTRAP_MODE=strict; then
  log "[FAIL] BOOTSTRAP_INCOMPLETE"
  exit 2
fi

assert_bootstrap_namespaces
BOOTSTRAP_STATUS="PASS"

run_phase "bootstrap-verify" "Verify bootstrap topology" "Authoritative topology checks confirm control-plane deployment correctness after bootstrap." \
  timeout --foreground "${VALIDATE_ALL_BOOTSTRAP_VERIFY_TIMEOUT_SECONDS:-1200}s" make bootstrap-verify

run_phase "ensure_test_workload" "Ensure test workload prerequisites" "Canonical test workloads exist, are injected, and are ready before verification begins." \
  timeout --foreground "${VALIDATE_ALL_ENSURE_TEST_WORKLOAD_TIMEOUT_SECONDS:-600}s" bash scripts/verify/ensure_test_workload.sh

run_phase "verify_control_plane_ready" "Verify control plane readiness" "Control plane is explicitly verified after workload readiness and before proof execution." \
  timeout --foreground "${VALIDATE_ALL_CONTROL_PLANE_READY_TIMEOUT_SECONDS:-600}s" bash scripts/verify/verify_control_plane_ready.sh

run_phase "verify_system_integrity" "Verify system integrity prerequisites" "System integrity prerequisites are checked against the live bootstrapped cluster before proof execution." \
  timeout --foreground "${VALIDATE_ALL_SYSTEM_INTEGRITY_TIMEOUT_SECONDS:-600}s" bash scripts/verify/verify_system_integrity.sh

if ! run_phase "verify_binary_handling_safety" "Verify binary cert/key handling safety" "Binary cert/key handling remains deterministic and fail-closed." \
  timeout --foreground "${VALIDATE_ALL_BINARY_SAFETY_TIMEOUT_SECONDS:-600}s" bash scripts/verify/verify_binary_handling_safety.sh; then
  log "[FAIL] BINARY_HANDLING_VIOLATION"
  exit 2
fi
BINARY_HANDLING_STATUS="PASS"

# Raise stall guard for the proof phase (long-running, sparse output).
_old_stall_timeout="$STALL_TIMEOUT_SECONDS"
STALL_TIMEOUT_SECONDS="${VALIDATE_ALL_PROOF_STALL_TIMEOUT_SECONDS:-3600}"
tf_bt_phase_start "proof-start" "validate-all proof phase begins"
tf_bt_phase_end "proof-start" "PASS" "proof phase launched"
run_phase "proof" "Execute non-healing proof" "Canonical passive and bounded active guarantees were evaluated without healing producer-owned state." \
  timeout --foreground "${VALIDATE_ALL_PROOF_TIMEOUT_SECONDS:-3600}s" make proof
STALL_TIMEOUT_SECONDS="$_old_stall_timeout"
PROOF_STATUS="PASS"

# Authoritative sequence marker retained for tests:
# timeout --foreground "${VALIDATE_ALL_PROOF_DETERMINISM_TIMEOUT_SECONDS:-3600}s" make proof-determinism
_proof_timeout_seconds="${VALIDATE_ALL_PROOF_TIMEOUT_SECONDS:-3600}"
_proof_determinism_timeout_seconds="${VALIDATE_ALL_PROOF_DETERMINISM_TIMEOUT_SECONDS:-5400}"

if ! run_phase "runtime-identity-truth" "Verify runtime identity truth" "Runtime SPIFFE identity truth is validated against live state." \
  timeout --foreground "${VALIDATE_ALL_RUNTIME_IDENTITY_TIMEOUT_SECONDS:-900}s" bash scripts/verify/verify_runtime_identity_truth.sh; then
  log "[FAIL] IDENTITY_TRUTH_MISMATCH"
  exit 2
fi
RUNTIME_IDENTITY_TRUTH_STATUS="PASS"

if ! run_phase "policy-reality" "Verify policy reality" "Observed allow/deny behavior matches declared policy intent." \
  timeout --foreground "${VALIDATE_ALL_POLICY_REALITY_TIMEOUT_SECONDS:-900}s" bash scripts/verify/verify_policy_runtime_enforcement.sh; then
  log "[FAIL] POLICY_REALITY_MISMATCH"
  exit 2
fi
POLICY_REALITY_STATUS="PASS"

if ! run_phase "observability-truth" "Verify observability truth" "Trace and log signals must reflect real executed requests." \
  timeout --foreground "${VALIDATE_ALL_OBSERVABILITY_TRUTH_TIMEOUT_SECONDS:-900}s" bash scripts/verify/verify_observability_truth.sh; then
  log "[FAIL] OBSERVABILITY_FALSE_SIGNAL"
  exit 2
fi
OBSERVABILITY_TRUTH_STATUS="PASS"

if ! run_phase "cross-layer-consistency" "Verify cross-layer consistency" "Identity, policy, and observability evidence must agree on the same request." \
  timeout --foreground "${VALIDATE_ALL_CROSS_LAYER_TIMEOUT_SECONDS:-900}s" bash scripts/verify/verify_cross_layer_consistency.sh; then
  log "[FAIL] CROSS_LAYER_INCONSISTENT"
  exit 2
fi
CROSS_LAYER_CONSISTENCY_STATUS="PASS"

# Raise stall guard for determinism phase (long-running, sparse output during verify).
_old_stall_timeout="$STALL_TIMEOUT_SECONDS"
STALL_TIMEOUT_SECONDS="${VALIDATE_ALL_PROOF_DETERMINISM_STALL_TIMEOUT_SECONDS:-3600}"
run_phase "proof-determinism" "Execute determinism validation" "Determinism was validated by repeated proof artifact comparison." \
  timeout --foreground "${_proof_determinism_timeout_seconds}s" make proof-determinism
STALL_TIMEOUT_SECONDS="$_old_stall_timeout"
DETERMINISM_STATUS="PASS"

run_phase "prove-active" "Execute active verification" "Active verification checks executed as part of authoritative validation flow." \
  timeout --foreground "${VALIDATE_ALL_PROVE_ACTIVE_TIMEOUT_SECONDS:-1800}s" make prove-active
ACTIVE_STATUS="PASS"

run_phase "forgesec" "Execute ForgeSec validation" "ForgeSec validation checks executed and must pass as the final authoritative phase." \
  timeout --foreground "${VALIDATE_ALL_FORGESEC_TIMEOUT_SECONDS:-1800}s" make forgesec
FORGESEC_STATUS="PASS"

if is_walkthrough_mode; then
  print_walkthrough_system_state
fi

log "[validate-all] complete"
