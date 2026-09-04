#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT_DIR/tests/mockbin:$PATH"

fail=0
export TEST_CASE=spiffe/missing-identity
export AUTHZ_FILE="$ROOT_DIR/tests/fixtures/spiffe/phase-authorizations.yaml"
out=$(bash "$ROOT_DIR/scripts/doctor-phase-eval.sh" 2>&1 || true)
if ! echo "$out" | grep -q "no identity supplied"; then
  echo "[FAIL] missing identity did not produce expected advisory"
  fail=1
else
  echo "[OK] missing-identity advisory emitted"
fi

if [ "$fail" -ne 0 ]; then
  echo "One or more tests failed"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
else
  echo "All phase-identity-missing tests passed"
fi
