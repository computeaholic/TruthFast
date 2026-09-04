#!/bin/bash
# wait_for_test_full.sh - Monitor test-full completion and prepare next validations

set -euo pipefail

LOG_FILE="/tmp/threadforge-test-full.log"
EXIT_CODE_FILE="${TEST_FULL_EXIT_CODE_FILE:-/tmp/threadforge-test-full.exitcode}"
TIMEOUT_SECONDS=$((60 * 120))  # 2 hour timeout
CHECK_INTERVAL=30  # Check every 30 seconds
ELAPSED=0

echo "[MONITOR] Starting test-full completion monitor"
echo "[MONITOR] Timeout: ${TIMEOUT_SECONDS}s, Check interval: ${CHECK_INTERVAL}s"

while [[ $ELAPSED -lt $TIMEOUT_SECONDS ]]; do
    # Check if process is still running
    if ! pgrep -f "make test-full" >/dev/null 2>&1; then
        echo "[MONITOR] test-full process completed"

        if [[ ! -f "$EXIT_CODE_FILE" ]]; then
            echo "[ERROR] authoritative exit code file missing: $EXIT_CODE_FILE"
            exit 2
        fi

        exit_code="$(cat "$EXIT_CODE_FILE")"
        if ! [[ "$exit_code" =~ ^[0-9]+$ ]]; then
            echo "[ERROR] invalid exit code recorded in $EXIT_CODE_FILE: $exit_code"
            exit 2
        fi

        if [[ "$exit_code" -ne 0 ]]; then
            echo "[MONITOR] Exit status: FAILURE (authoritative exit code $exit_code)"
            tail -50 "$LOG_FILE" 2>/dev/null || true
            exit "$exit_code"
        fi

        echo "[MONITOR] Exit status: PASS (authoritative exit code 0)"
        tail -5 "$LOG_FILE" 2>/dev/null || true

        echo "[MONITOR] Ready for next validation phase"
        echo "[MONITOR] Next steps:"
        echo "  1. Review /tmp/threadforge-test-full.log results"
        echo "  2. Run: make validate-all"
        echo "  3. Run: /scripts/verify/verify_mode_artifact_parity.sh"
        exit 0
    fi

    ELAPSED=$((ELAPSED + CHECK_INTERVAL))
    LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
    echo "[MONITOR] Elapsed ${ELAPSED}s - Log: ${LINES} lines"
    sleep $CHECK_INTERVAL
done

echo "[ERROR] test-full timeout exceeded (${TIMEOUT_SECONDS}s)"
exit 1
