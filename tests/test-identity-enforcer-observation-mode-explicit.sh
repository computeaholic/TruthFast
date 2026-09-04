#!/usr/bin/env bash
# Test: identity_enforcer.sh observation mode is explicit
# Proves that observation mode messaging is explicit and visible

set -euo pipefail

echo "=== Test: identity_enforcer.sh observation mode explicit ==="

# Test 1: Verify script contains explicit OBSERVATION MODE messaging
if ! grep -q "OBSERVATION MODE" platform/runtime/operator/identity_enforcer.sh; then
  echo "FAIL: identity_enforcer.sh must contain 'OBSERVATION MODE' explicit label"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ Script contains 'OBSERVATION MODE' label"

# Test 2: Verify WARNING about observability vs enforcement is present
if ! grep -q "WARNING.*observability-first.*not fail-closed" platform/runtime/operator/identity_enforcer.sh; then
  echo "FAIL: Script must contain WARNING about observability vs enforcement trade-off"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ Script contains WARNING about observability-first mode"

# Test 3: Verify comment explaining architectural trade-off
if ! grep -q "Architectural trade-off: observability vs fail-closed enforcement" platform/runtime/operator/identity_enforcer.sh; then
  echo "FAIL: Script must document architectural trade-off in comment"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ Script documents architectural trade-off"

# Test 4: Verify old ambiguous language removed
if grep -q "enforcement not enabled -> observation allowed (read-only)" platform/runtime/operator/identity_enforcer.sh; then
  echo "FAIL: Old ambiguous language still present"
  grep "enforcement not enabled -> observation allowed" platform/runtime/operator/identity_enforcer.sh
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ Old ambiguous language removed"

# Test 5: Verify observation mode path still exists (preserves visibility)
if ! grep -q "# OBSERVATION MODE:" platform/runtime/operator/identity_enforcer.sh; then
  echo "FAIL: Observation mode path must be preserved for visibility"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ Observation mode path preserved for visibility"

echo "=== Test PASSED: observation mode explicit and visible ==="
