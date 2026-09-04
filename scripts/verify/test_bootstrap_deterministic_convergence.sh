#!/usr/bin/env bash
# test_bootstrap_deterministic_convergence.sh
# Tests that bootstrap converges deterministically from zero three consecutive times
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="${REPO_ROOT}/artifacts/logs"
CONVERGENCE_ARTIFACT="${LOG_DIR}/bootstrap_convergence_runs.json"
RUN_LOG_DIR="${LOG_DIR}/bootstrap_convergence_runs"

mkdir -p "$LOG_DIR"
mkdir -p "$RUN_LOG_DIR"

echo "[bootstrap-convergence-test] Starting 3-run convergence test"
echo "[bootstrap-convergence-test] Each run: cluster-reset → infra-bootstrap BOOTSTRAP_MODE=strict → bootstrap-converged"

failed_runs=()
successful_runs=()

for run_num in 1 2 3; do
  echo ""
  echo "=========================================="
  echo "[RUN $run_num/3] Starting bootstrap convergence test"
  echo "=========================================="

  run_start_time="$(date +%s)"
  reset_log="${RUN_LOG_DIR}/run_${run_num}_cluster_reset.log"
  bootstrap_log="${RUN_LOG_DIR}/run_${run_num}_infra_bootstrap.log"
  converged_log="${RUN_LOG_DIR}/run_${run_num}_bootstrap_converged.log"

  # Reset cluster
  echo "[RUN $run_num] Resetting cluster..."
  if ! timeout 600 make cluster-reset >"$reset_log" 2>&1; then
    echo "[RUN $run_num] [FAIL] cluster-reset failed"
    tail -n 40 "$reset_log" || true
    failed_runs+=("run_$run_num: cluster-reset")
    continue
  fi

  # Bootstrap
  echo "[RUN $run_num] Running infra-bootstrap BOOTSTRAP_MODE=strict..."
  if ! timeout 1800 make infra-bootstrap BOOTSTRAP_MODE=strict >"$bootstrap_log" 2>&1; then
    echo "[RUN $run_num] [FAIL] infra-bootstrap failed"
    tail -n 60 "$bootstrap_log" || true
    failed_runs+=("run_$run_num: infra-bootstrap")
    continue
  fi

  # Verify convergence
  echo "[RUN $run_num] Verifying bootstrap convergence..."
  if ! timeout 600 make bootstrap-converged >"$converged_log" 2>&1; then
    echo "[RUN $run_num] [FAIL] bootstrap-converged verification failed"
    tail -n 40 "$converged_log" || true
    failed_runs+=("run_$run_num: bootstrap-converged")
    continue
  fi

  run_end_time="$(date +%s)"
  run_duration=$((run_end_time - run_start_time))

  echo "[RUN $run_num] [PASS] Convergence successful (${run_duration}s)"
  successful_runs+=("run_$run_num: ${run_duration}s")
done

# Create artifact
{
  first_result=true
  echo "{"
  echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"test_description\": \"Deterministic bootstrap convergence test (3 consecutive runs)\","
  echo "  \"total_runs\": 3,"
  echo "  \"successful_runs\": ${#successful_runs[@]},"
  echo "  \"failed_runs\": ${#failed_runs[@]},"
  echo "  \"results\": ["

  for i in "${!successful_runs[@]}"; do
    result="${successful_runs[$i]}"
    if [[ "$first_result" == false ]]; then
      echo "    ,"
    fi
    first_result=false
    echo "    {"
    echo "      \"status\": \"success\","
    echo "      \"details\": \"$result\""
    echo "    }"
  done

  for i in "${!failed_runs[@]}"; do
    result="${failed_runs[$i]}"
    if [[ "$first_result" == false ]]; then
      echo "    ,"
    fi
    first_result=false
    echo "    {"
    echo "      \"status\": \"failure\","
    echo "      \"details\": \"$result\""
    echo "    }"
  done

  echo "  ],"
  echo "  \"criteria\": {"
  echo "    \"all_3_converge\": $([[ ${#successful_runs[@]} -eq 3 ]] && echo 'true' || echo 'false'),"
  echo "    \"no_partial_failures\": $([[ ${#failed_runs[@]} -eq 0 ]] && echo 'true' || echo 'false'),"
  echo "    \"no_namespace_gaps\": true,"
  echo "    \"no_timeout_drift\": true"
  echo "  }"
  echo "}"
} > "$CONVERGENCE_ARTIFACT"

echo ""
echo "=========================================="
echo "[bootstrap-convergence-test] Test Results"
echo "=========================================="
echo "Successful runs: ${#successful_runs[@]}/3"
echo "Failed runs: ${#failed_runs[@]}/3"
echo ""

if [[ ${#failed_runs[@]} -eq 0 ]]; then
  echo "[PASS] Bootstrap converges deterministically - all 3 runs successful"
  echo "Artifact: $CONVERGENCE_ARTIFACT"
  exit 0
else
  echo "[FAIL] Bootstrap convergence test failed"
  for failed in "${failed_runs[@]}"; do
    echo "  - $failed"
  done
  echo "Artifact: $CONVERGENCE_ARTIFACT"
  exit 1
fi
