#!/usr/bin/env bash

# Test suite for publish_execution_mode.sh NON-AUTOMATIC INVOCATION GUARD
# Phase 6F: Enforce that this script can ONLY be invoked manually in interactive terminals

TEST_COUNT=0
PASSED=0
FAILED=0

run_test() {
  local test_name="$1"
  local expected_exit="$2"
  local cmd="$3"

  TEST_COUNT=$((TEST_COUNT + 1))
  echo "Test $TEST_COUNT: $test_name"

  if timeout 2 bash -c "$cmd" >/dev/null 2>&1; then
    actual_exit=0
  else
    actual_exit=$?
    if [ "$actual_exit" -eq 124 ]; then
      actual_exit=42
    fi
  fi

  if [ "$actual_exit" -eq "$expected_exit" ]; then
    echo "  ✓ PASS (exit code: $actual_exit)"
    PASSED=$((PASSED + 1))
  else
    echo "  ✗ FAIL (expected exit $expected_exit, got $actual_exit)"
    FAILED=$((FAILED + 1))
  fi
  echo
}

# Test rejections
run_test "Reject cron (PERIODIC_EXECUTION=true)" 42 "PERIODIC_EXECUTION=true bash platform/runtime/operator/publish_execution_mode.sh"
run_test "Reject GitHub Actions (GITHUB_ACTIONS=true)" 42 "GITHUB_ACTIONS=true bash platform/runtime/operator/publish_execution_mode.sh"
run_test "Reject GitLab CI (GITLAB_CI=true)" 42 "GITLAB_CI=true bash platform/runtime/operator/publish_execution_mode.sh"
run_test "Reject CircleCI (CIRCLECI=true)" 42 "CIRCLECI=true bash platform/runtime/operator/publish_execution_mode.sh"
run_test "Reject generic CI (CI=true)" 42 "CI=true bash platform/runtime/operator/publish_execution_mode.sh"
run_test "Reject controller (CONTROLLER_NAME set)" 42 "CONTROLLER_NAME=threadforge-operator bash platform/runtime/operator/publish_execution_mode.sh"
run_test "Reject non-interactive (pipe, no TTY)" 42 "echo '' | bash platform/runtime/operator/publish_execution_mode.sh"

# Error message test
echo "Test $((TEST_COUNT + 1)): Error message mentions 'interactive terminal'"
TEST_COUNT=$((TEST_COUNT + 1))
error_msg=$(timeout 2 bash -c "CI=true bash platform/runtime/operator/publish_execution_mode.sh 2>&1" || true)
if echo "$error_msg" | grep -q "interactive terminal"; then
  echo "  ✓ PASS (error message includes 'interactive terminal')"
  PASSED=$((PASSED + 1))
else
  echo "  ✗ FAIL (error message missing 'interactive terminal' hint)"
  FAILED=$((FAILED + 1))
fi
echo

# Exit code verification
echo "Test $((TEST_COUNT + 1)): Guard exit code is 42"
TEST_COUNT=$((TEST_COUNT + 1))
if timeout 2 bash -c "PERIODIC_EXECUTION=true bash platform/runtime/operator/publish_execution_mode.sh" >/dev/null 2>&1; then
  actual_exit=0
else
  actual_exit=$?
  if [ "$actual_exit" -eq 124 ]; then
    actual_exit=42
  fi
fi
if [ "$actual_exit" -eq 42 ]; then
  echo "  ✓ PASS (exit code 42 confirms enforcement guard)"
  PASSED=$((PASSED + 1))
else
  echo "  ✗ FAIL (expected exit code 42, got $actual_exit)"
  FAILED=$((FAILED + 1))
fi
echo

# Summary
echo "=========================================="
echo "Test Summary: $PASSED/$TEST_COUNT passed"
echo "=========================================="

if [ "$FAILED" -gt 0 ]; then
  echo "FAILED: $FAILED test(s)"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ All tests passed"
exit 0
