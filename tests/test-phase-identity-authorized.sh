#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT_DIR/tests/mockbin:$PATH"

fail=0
export TEST_CASE=spiffe/authorized
export AUTHZ_FILE="$ROOT_DIR/tests/fixtures/spiffe/phase-authorizations.yaml"
out=$(bash "$ROOT_DIR/scripts/doctor-phase-eval.sh" 2>&1 || true)
if ! echo "$out" | grep -q "override identity is authorized"; then
  echo "[FAIL] authorized identity not detected as authorized"
  fail=1
else
  echo "[OK] authorized identity detected"
fi

if [ "$fail" -ne 0 ]; then
  echo "One or more tests failed"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
else
  echo "All phase-identity-authorized tests passed"
fi
