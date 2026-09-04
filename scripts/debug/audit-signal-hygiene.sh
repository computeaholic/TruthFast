#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

echo "Signal Hygiene Audit"
echo "======================"

# Patterns to check
PATTERNS=(
  "log_level: trace"
  "log_level: debug"
  "sampling: 100"
  "sampling: [5-9][0-9]"
  "randomSamplingPercentage: [1-9][0-9]"
  "sampling_percentage: [5-9][0-9]"
)

echo "-- Searching for debug/trace log levels and high sampling --"
for p in "${PATTERNS[@]}"; do
  echo "Pattern: $p"
  grep -RIn --exclude-dir=.git --exclude=*.lock --line-number -E "$p" || true
  echo
done

# Check for Tempo/Prometheus retention thresholds
echo "-- Checking retention settings --"
# Tempo
grep -RIn --exclude-dir=.git --line-number -E "tempo.*retention|block_retention:|retention:\s*[0-9]+h|retention:\s*[0-9]+d" deploy || true
# Prometheus
grep -RIn --exclude-dir=.git --line-number -E "prometheus.*retention|retention:\s*[0-9]+d|retention:\s*[0-9]+h" deploy || true

echo
# Summarize probable issues
echo "-- Quick Summary --"
if grep -RIn --exclude-dir=.git -E "log_level: trace|log_level: debug|sampling: 100|sampling: [5-9][0-9]|randomSamplingPercentage: [1-9][0-9]|sampling_percentage: [5-9][0-9]" > /dev/null 2>&1; then
  echo "Potential noisy configs found (high sampling or debug log levels). Review the grep output above." 
else
  echo "No obvious high-sampling or trace/debug log levels found." 
fi

exit 0
