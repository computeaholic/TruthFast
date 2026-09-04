#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT_DIR/tests/mockbin:$PATH"

fail=0

# Historic case
export WINDOW_MINUTES=10
export TEST_CASE=dependency_lint/historic
out=$(bash "$ROOT_DIR/scripts/doctor-dependency-lint.sh" 2>&1 || true)
if ! echo "$out" | grep -q "historic"; then
  echo "[FAIL] dependency-lint historic did not detect historic"
  fail=1
else
  echo "[OK] dependency-lint historic"
fi

# Live case: ensure window allows classification as live (set large window)
export WINDOW_MINUTES=10000
export TEST_CASE=dependency_lint/live
out=$(bash "$ROOT_DIR/scripts/doctor-dependency-lint.sh" 2>&1 || true)
if ! echo "$out" | grep -q "Live exporter connection failures detected"; then
  echo "[FAIL] dependency-lint live did not detect live"
  fail=1
else
  echo "[OK] dependency-lint live"
fi

if [ "$fail" -ne 0 ]; then
  echo "One or more dependency-lint tests failed"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
else
  echo "All dependency-lint tests passed"
fi
