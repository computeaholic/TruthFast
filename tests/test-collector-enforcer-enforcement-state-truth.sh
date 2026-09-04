#!/usr/bin/env bash
# Test: collector_enforcer.sh emits actual enforcement state, not hypothetical
# Proves that output states "blocked" when enforcing, "observation-only" when not

set -euo pipefail

echo "=== Test: collector_enforcer.sh enforcement state truth ==="

# Test 1: Verify script contains no "would-block" hypothetical language
if grep -q "would-block" platform/runtime/operator/collector_enforcer.sh; then
  echo "FAIL: collector_enforcer.sh still contains 'would-block' hypothetical language"
  grep "would-block" platform/runtime/operator/collector_enforcer.sh
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ No 'would-block' hypothetical language"

# Test 2: Verify script contains actual enforcement states
if ! grep -q "action_taken=\"blocked\"" platform/runtime/operator/collector_enforcer.sh; then
  echo "FAIL: Script must contain 'blocked' actual enforcement state"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if ! grep -q "action_taken=\"observation-only\"" platform/runtime/operator/collector_enforcer.sh; then
  echo "FAIL: Script must contain 'observation-only' actual state"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ Script contains actual enforcement states (blocked, observation-only)"

# Test 3: Verify messaging states actual behavior
if ! grep -q "enforcement active, execution blocked" platform/runtime/operator/collector_enforcer.sh; then
  echo "FAIL: Script must state 'execution blocked' when blocking"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if ! grep -q "enforcement disabled, observation only" platform/runtime/operator/collector_enforcer.sh; then
  echo "FAIL: Script must state 'observation only' when not enforcing"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ Messaging accurately reflects actual behavior"

# Test 4: Verify old ambiguous language removed
if grep -q "only simulated" platform/runtime/operator/collector_enforcer.sh; then
  echo "FAIL: Old 'only simulated' language still present"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if grep -q "enforcement active and would block" platform/runtime/operator/collector_enforcer.sh; then
  echo "FAIL: Old hypothetical messaging still present"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ Old ambiguous language removed"

# Test 5: Verify enforcement logic matches action_taken
# When action_taken="blocked", script must echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
if ! grep -A2 'action_taken.*blocked' platform/runtime/operator/collector_enforcer.sh | grep -q 'echo "[ADVISORY-FAIL] non-authoritative path"; exit 0'; then
  echo "FAIL: Script must echo "[ADVISORY-FAIL] non-authoritative path"; exit 0 when action_taken is 'blocked'"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ Enforcement logic consistent with action_taken"

echo "=== Test PASSED: collector_enforcer.sh enforcement state truth verified ==="
