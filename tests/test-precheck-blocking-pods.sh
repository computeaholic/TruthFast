#!/usr/bin/env bash
# test-precheck-blocking-pods.sh — hermetic unit test for verify_precheck_blocking_pods.sh
#
# Tests the precheck script in isolation using mock kubectl output.
# No real cluster required. Uses KUBECTL_OUTPUT env var for injection.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/verify/verify_precheck_blocking_pods.sh"

fail=0
pass=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
run_case() {
  local label="$1"
  local expected_ec="$2"
  local expected_pattern="$3"
  local kubectl_mock="$4"

  local actual_ec=0
  out="$(LOG_DIR="$tmpdir" KUBECTL_OUTPUT="$kubectl_mock" bash "$SCRIPT" 2>&1)" || actual_ec=$?

  if [ "$actual_ec" -ne "$expected_ec" ]; then
    echo "[FAIL] $label: expected exit $expected_ec, got $actual_ec"
    echo "       output: $out"
    fail=$(( fail + 1 ))
    return
  fi

  if ! echo "$out" | grep -qE "$expected_pattern"; then
    echo "[FAIL] $label: expected pattern '$expected_pattern' not found in output"
    echo "       output: $out"
    fail=$(( fail + 1 ))
    return
  fi

  echo "[OK]   $label"
  pass=$(( pass + 1 ))
}

assert_artifact_field() {
  local label="$1"
  local field="$2"
  local expected="$3"

  local artifact="$tmpdir/precheck_blocking_pods.json"
  if [ ! -f "$artifact" ]; then
    echo "[FAIL] $label: artifact not written at $artifact"
    fail=$(( fail + 1 ))
    return
  fi

  actual="$(python3 -c "import json,sys; d=json.load(open('$artifact')); print(d.get('$field','MISSING'))" 2>/dev/null)"
  if [ "$actual" != "$expected" ]; then
    echo "[FAIL] $label: artifact field '$field' = '$actual', expected '$expected'"
    fail=$(( fail + 1 ))
    return
  fi

  echo "[OK]   $label (artifact.$field=$expected)"
  pass=$(( pass + 1 ))
}

assert_artifact_pod_count() {
  local label="$1"
  local expected="$2"

  local artifact="$tmpdir/precheck_blocking_pods.json"
  if [ ! -f "$artifact" ]; then
    echo "[FAIL] $label: artifact not written"
    fail=$(( fail + 1 ))
    return
  fi

  actual="$(python3 -c "import json,sys; d=json.load(open('$artifact')); print(len(d.get('blocking_pods',[])))" 2>/dev/null)"
  if [ "$actual" != "$expected" ]; then
    echo "[FAIL] $label: artifact blocking_pod_count = $actual, expected $expected"
    fail=$(( fail + 1 ))
    return
  fi

  echo "[OK]   $label (artifact.blocking_pods count=$expected)"
  pass=$(( pass + 1 ))
}

# ---------------------------------------------------------------------------
# Mock kubectl JSON payloads
# ---------------------------------------------------------------------------

CLEAN_JSON='{"apiVersion":"v1","kind":"PodList","items":[]}'

CRASHLOOP_JSON=$(python3 -c "
import json
pods = {
  'apiVersion': 'v1',
  'kind': 'PodList',
  'items': [
    {
      'metadata': {'name': 'api-server-7d9b4', 'namespace': 'threadforge'},
      'status': {
        'phase': 'Running',
        'containerStatuses': [
          {
            'name': 'api',
            'state': {'waiting': {'reason': 'CrashLoopBackOff', 'message': 'Back-off restarting'}},
            'ready': False,
            'restartCount': 8
          }
        ]
      }
    }
  ]
}
print(json.dumps(pods))
")

PENDING_JSON=$(python3 -c "
import json
pods = {
  'apiVersion': 'v1',
  'kind': 'PodList',
  'items': [
    {
      'metadata': {'name': 'worker-abc12', 'namespace': 'default'},
      'status': {
        'phase': 'Pending',
        'containerStatuses': []
      }
    }
  ]
}
print(json.dumps(pods))
")

MIXED_JSON=$(python3 -c "
import json
pods = {
  'apiVersion': 'v1',
  'kind': 'PodList',
  'items': [
    {
      'metadata': {'name': 'good-pod', 'namespace': 'kube-system'},
      'status': {
        'phase': 'Running',
        'containerStatuses': [
          {'name': 'c1', 'state': {'running': {}}, 'ready': True, 'restartCount': 0}
        ]
      }
    },
    {
      'metadata': {'name': 'bad-pod', 'namespace': 'spire-system'},
      'status': {
        'phase': 'Running',
        'containerStatuses': [
          {
            'name': 'spire-agent',
            'state': {'waiting': {'reason': 'ImagePullBackOff', 'message': 'pull failed'}},
            'ready': False,
            'restartCount': 0
          }
        ]
      }
    }
  ]
}
print(json.dumps(pods))
")

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------
rm -f "$tmpdir/precheck_blocking_pods.json"

# Case 1: Clean cluster → exit 0, PASS message
run_case "clean cluster" 0 "\[PASS\]" "$CLEAN_JSON"
assert_artifact_field "clean cluster: artifact.clean" "clean" "True"
assert_artifact_pod_count "clean cluster: no blocking pods" "0"

rm -f "$tmpdir/precheck_blocking_pods.json"

# Case 2: CrashLoopBackOff pod → exit 2, POLICY_VIOLATION message
run_case "CrashLoopBackOff → exit 2" 2 "POLICY_VIOLATION" "$CRASHLOOP_JSON"
assert_artifact_field "CrashLoopBackOff: artifact.clean" "clean" "False"
assert_artifact_pod_count "CrashLoopBackOff: 1 blocking pod" "1"

rm -f "$tmpdir/precheck_blocking_pods.json"

# Case 3: Pending pod → exit 2, POLICY_VIOLATION message
run_case "Pending pod → exit 2" 2 "POLICY_VIOLATION" "$PENDING_JSON"
assert_artifact_pod_count "Pending: 1 blocking pod" "1"

rm -f "$tmpdir/precheck_blocking_pods.json"

# Case 4: Mixed (one clean, one ImagePullBackOff) → exit 2
run_case "mixed: ImagePullBackOff → exit 2" 2 "POLICY_VIOLATION" "$MIXED_JSON"
assert_artifact_pod_count "mixed: 1 blocking pod" "1"

rm -f "$tmpdir/precheck_blocking_pods.json"

# Case 5: Namespace and pod name are captured in output
CRASHLOOP_JSON_NS=$(python3 -c "
import json
pods = {
  'apiVersion': 'v1',
  'kind': 'PodList',
  'items': [
    {
      'metadata': {'name': 'my-crasher', 'namespace': 'govern-ns'},
      'status': {
        'phase': 'Running',
        'containerStatuses': [
          {
            'name': 'proxy',
            'state': {'waiting': {'reason': 'CrashLoopBackOff'}},
            'ready': False,
            'restartCount': 5
          }
        ]
      }
    }
  ]
}
print(json.dumps(pods))
")
run_case "namespace+pod captured in output" 2 "govern-ns" "$CRASHLOOP_JSON_NS"
run_case "pod name in output" 2 "my-crasher" "$CRASHLOOP_JSON_NS"

rm -f "$tmpdir/precheck_blocking_pods.json"

# Case 6: Empty output → exit 2 (unknown state)
run_case "empty kubectl output → exit 2" 2 "POLICY.VIOLATION" ""

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$fail" -eq 0 ]; then
  echo "[PASS] all $pass test cases passed"
  exit 0
else
  echo "[FAIL] $fail test case(s) failed ($pass passed)"
  exit 1
fi
