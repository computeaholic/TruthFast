#!/bin/bash
set -euo pipefail

# auto_run_validations.sh
# Waits for test-full completion, then runs validate-all and parity check
# Usage: ./auto_run_validations.sh

REPO_ROOT="/home/threadforge/threadforge"
MONITOR_LOG="/tmp/test_full_monitor.log"
TEST_FULL_LOG="/tmp/threadforge-test-full.log"
EXIT_CODE_FILE="${TEST_FULL_EXIT_CODE_FILE:-/tmp/threadforge-test-full.exitcode}"
VALIDATE_ALL_LOG="/tmp/threadforge-validate-all.log"

echo "[AUTO] Waiting for test-full completion..."
echo "[AUTO] This script will automatically run validate-all and parity checks"
echo "[AUTO] Monitor: watch -n 5 'tail -1 $TEST_FULL_LOG && ps aux | grep make | grep -v grep | wc -l'"

cd "$REPO_ROOT"

# Wait for test-full process to finish
while pgrep -f "make test-full" >/dev/null 2>&1; do
    sleep 30
    lines=$(wc -l < "$TEST_FULL_LOG" 2>/dev/null || echo "0")
    echo "[AUTO] Still running... ($lines lines logged)"
done

echo "[AUTO] test-full completed!"
echo "[AUTO] Checking results..."

if [[ ! -f "$EXIT_CODE_FILE" ]]; then
    echo "[AUTO] ✗ authoritative exit code file missing: $EXIT_CODE_FILE"
    exit 2
fi

test_full_rc="$(cat "$EXIT_CODE_FILE")"
if ! [[ "$test_full_rc" =~ ^[0-9]+$ ]]; then
    echo "[AUTO] ✗ invalid exit code recorded in $EXIT_CODE_FILE: $test_full_rc"
    exit 2
fi

if [[ "$test_full_rc" -ne 0 ]]; then
    echo "[AUTO] ✗ test-full returned exit code: $test_full_rc"
    tail -20 "$TEST_FULL_LOG" 2>/dev/null || true
    exit "$test_full_rc"
fi

# Extract test-full summary
if tail -20 "$TEST_FULL_LOG" | grep -q "passed in"; then
    echo "[AUTO] ✓ pytest completed"
    tail -5 "$TEST_FULL_LOG"
else
    echo "[AUTO] ✗ Check test-full log for details"
fi

echo ""
echo "[AUTO] Starting validate-all (this may take 45-60 minutes)..."
set +e
timeout 3600 make validate-all 2>&1 | tee "$VALIDATE_ALL_LOG"
validate_all_rc=$?
set -e
if [[ "$validate_all_rc" -ne 0 ]]; then
    echo "[AUTO] validate-all returned exit code: $validate_all_rc"
    exit "$validate_all_rc"
fi

echo ""
echo "[AUTO] Running artifact parity verification..."
if [[ -f "scripts/verify/verify_mode_artifact_parity.sh" ]]; then
    bash "scripts/verify/verify_mode_artifact_parity.sh" capture test-cluster || true
    bash "scripts/verify/verify_mode_artifact_parity.sh" capture test-full || true
    bash "scripts/verify/verify_mode_artifact_parity.sh" cluster full || true
else
    echo "[AUTO] ✗ Parity script not found"
fi

echo ""
echo "[AUTO] Generating timing summary..."
if [[ -f "scripts/verify/mode_timing_summary.sh" ]]; then
    bash "scripts/verify/mode_timing_summary.sh" \
        "$TEST_FULL_LOG" \
        "$VALIDATE_ALL_LOG" || true
fi

echo ""
echo "[AUTO] ✓ Validation sequence complete!"
echo "[AUTO] Results:"
echo "  test-cluster: $TEST_FULL_LOG"
echo "  test-full: $TEST_FULL_LOG"
echo "  validate-all: $VALIDATE_ALL_LOG"
