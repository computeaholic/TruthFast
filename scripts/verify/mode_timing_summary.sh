#!/bin/bash
set -euo pipefail

# mode_timing_summary.sh
# Extracts timing information from test mode execution logs
# Usage: ./mode_timing_summary.sh <log_file> [log_file2 ...]

mode_timing_report() {
    local log_file="$1"
    local mode_name="${2:-unknown}"

    if [[ ! -f "$log_file" ]]; then
        echo "[WARN] Log file not found: $log_file"
        return 1
    fi

    # Extract TEST MODE and timing from pytest summary
    local test_mode=$(grep -E "^TEST MODE:" "$log_file" | head -1 | awk '{print $NF}')
    local result_line=$(grep -E "^[0-9]+ (failed|passed)" "$log_file" | tail -1)

    if [[ -z "$result_line" ]]; then
        echo "[WARN] Could not extract timing from: $log_file"
        return 1
    fi

    # Parse pytest summary format: "X failed, Y passed in Zs (HH:MM:SS)"
    local passed=$(echo "$result_line" | grep -oE '[0-9]+ passed' | awk '{print $1}')
    local failed=$(echo "$result_line" | grep -oE '[0-9]+ failed' | awk '{print $1}' || echo "0")
    local skipped=$(echo "$result_line" | grep -oE '[0-9]+ skipped' | awk '{print $1}' || echo "0")
    local seconds=$(echo "$result_line" | grep -oE '[0-9]+\.[0-9]+s' | sed 's/s//')
    local duration=$(echo "$result_line" | grep -oE '\([^)]+\)' | tr -d '()')

    printf "%-15s %-10s TESTS: %4d passed, %3d failed, %2d skipped  TIME: %8.2fs (%s)\n" \
        "$mode_name:" "$test_mode" "$passed" "$failed" "$skipped" "$seconds" "$duration"
}

echo "=== ThreadForge Mode Timing Summary ==="
echo ""

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <log_file> [log_file2 ...]"
    echo "Example: $0 /tmp/threadforge-test-cluster.log /tmp/threadforge-test-full.log"
    exit 1
fi

for log_file in "$@"; do
    mode_name=$(basename "$log_file" | sed 's/threadforge-//; s/.log//')
    mode_timing_report "$log_file" "$mode_name"
done

echo ""
echo "=== Comparison Notes ==="
echo "• test-cluster should be faster than test-full (no service provisioning)"
echo "• validate-all should be similar to test-full (full stack)"
echo "• All modes should have identical skip/failure patterns"
