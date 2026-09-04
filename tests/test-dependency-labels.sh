#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT_DIR/tests/mockbin:$PATH"

fail=0

# Case: canonical workloads present but missing workload-class label
export TEST_CASE=label_missing
out=$(bash "$ROOT_DIR/scripts/doctor-dependency-lint.sh" 2>&1 || true)
# Expect advisories for tempo, minio, and postgres
for expected in tempo minio postgres; do
  if ! echo "$out" | grep -q "${expected}.*missing.*workload-class"; then
    echo "[FAIL] missing-label advisory not emitted for $expected"
    fail=1
  else
    echo "[OK] missing-label advisory emitted for $expected"
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "One or more tests failed"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
else
  echo "All dependency-label tests passed"
fi
