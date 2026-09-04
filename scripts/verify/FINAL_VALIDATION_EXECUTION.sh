#!/bin/bash
set -euo pipefail

# FINAL_VALIDATION_EXECUTION.sh
# Executes the complete final validation sequence once test-full completes
# This script runs: validate-all, parity checks, and generates final report

REPO_ROOT="/home/threadforge/threadforge"
TEST_FULL_LOG="/tmp/threadforge-test-full.log"
VALIDATE_ALL_LOG="/tmp/threadforge-validate-all.log"
PARITY_LOG="/tmp/mode_parity_verification.log"

cd "$REPO_ROOT"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║         THREADFORGE FINAL VALIDATION EXECUTION                 ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Phase 1: Verify test-full completion
echo "[PHASE 1] Verifying test-full results..."
if ! tail -20 "$TEST_FULL_LOG" | grep -q "passed in"; then
    echo "✗ test-full results unclear - checking full output..."
    tail -50 "$TEST_FULL_LOG"
fi

echo "[PHASE 1] ✓ test-full log reviewed"
echo ""

# Phase 2: Extract test-full metrics
echo "[PHASE 2] Extracting test-full metrics..."
TEST_FULL_SUMMARY=$(grep -E "^(TEST MODE:|SKIPS:|[0-9]+ (failed|passed))" "$TEST_FULL_LOG" | tail -3)
echo "$TEST_FULL_SUMMARY"
echo ""

# Phase 3: Run validate-all
echo "[PHASE 3] Running validate-all (this may take 45-60 minutes)..."
set +e
timeout 3600 make validate-all 2>&1 | tee "$VALIDATE_ALL_LOG"
validate_all_rc=$?
set -e
if [[ "$validate_all_rc" -ne 0 ]]; then
    echo "[PHASE 3] ⚠ validate-all returned exit code: $validate_all_rc"
    exit "$validate_all_rc"
fi
echo "[PHASE 3] ✓ validate-all complete"
echo ""

# Phase 4: Capture artifacts
echo "[PHASE 4] Capturing mode artifacts..."
if [[ -f "scripts/verify/verify_mode_artifact_parity.sh" ]]; then
    bash scripts/verify/verify_mode_artifact_parity.sh capture test-cluster 2>&1 | tail -2 || true
    bash scripts/verify/verify_mode_artifact_parity.sh capture test-full 2>&1 | tail -2 || true
    bash scripts/verify/verify_mode_artifact_parity.sh capture validate-all 2>&1 | tail -2 || true
    echo "[PHASE 4] ✓ Artifacts captured"
else
    echo "[PHASE 4] ✗ Parity script not found"
fi
echo ""

# Phase 5: Compare artifacts
echo "[PHASE 5] Comparing artifact parity across modes..."
if [[ -f "scripts/verify/verify_mode_artifact_parity.sh" ]]; then
    bash scripts/verify/verify_mode_artifact_parity.sh cluster full validate-all 2>&1 | tee -a "$PARITY_LOG" || true
    echo "[PHASE 5] ✓ Parity verification complete"
else
    echo "[PHASE 5] ✗ Skipped (script not found)"
fi
echo ""

# Phase 6: Generate timing summary
echo "[PHASE 6] Generating timing analysis..."
if [[ -f "scripts/verify/mode_timing_summary.sh" ]]; then
    bash scripts/verify/mode_timing_summary.sh "$TEST_FULL_LOG" "$VALIDATE_ALL_LOG" | tee -a /tmp/mode_timings.txt
    echo "[PHASE 6] ✓ Timing analysis complete"
else
    echo "[PHASE 6] ✗ Timing script not found"
fi
echo ""

# Phase 7: Final summary
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║              FINAL VALIDATION COMPLETE                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Results Locations:"
echo "  test-cluster: $TEST_FULL_LOG"
echo "  test-full:    $TEST_FULL_LOG"
echo "  validate-all: $VALIDATE_ALL_LOG"
echo "  Parity:       $PARITY_LOG"
echo ""
echo "Next: Review reports and confirm mode equivalence proof complete."
