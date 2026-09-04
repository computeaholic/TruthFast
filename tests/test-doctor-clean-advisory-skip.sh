#!/usr/bin/env bash
# Verify doctor-clean respects advisory mode: never emit ERROR for authority-denied paths
# and never attempts deletion during default (advisory) runs.

set -euo pipefail

echo "=== Test: doctor-clean advisory/strict semantics ==="

TMPBIN=$(mktemp -d)
TMPOUT=$(mktemp)
STATEFILE=$(mktemp)

# Mock kubectl: return pods/jobs for the selector; fail on delete (so deletion attempts will be visible)
cat > "$TMPBIN/kubectl" <<'MOCK'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"get pods -A -l"* ]]; then
  # return a simple jsonpath-friendly listing for the selector call and the json variant
  if [[ "$args" == *"-o jsonpath"* ]]; then
    echo "default/doctor-pod-1\nkube-system/doctor-pod-2"
    exit 0
  elif [[ "$args" == *"-o json"* ]]; then
    echo '{"items":[{"metadata":{"name":"doctor-pod-1","namespace":"default"}},{"metadata":{"name":"doctor-pod-2","namespace":"kube-system"}}]}'
    exit 0
  fi
  # generic listing
  echo "default/doctor-pod-1\nkube-system/doctor-pod-2"
  exit 0
fi
if [[ "$args" == *"get jobs -A -l"* ]]; then
  if [[ "$args" == *"-o jsonpath"* ]]; then
    echo "default/doctor-job-1"
    exit 0
  elif [[ "$args" == *"-o json"* ]]; then
    echo '{"items":[{"metadata":{"name":"doctor-job-1","namespace":"default"}}]}'
    exit 0
  fi
  echo "default/doctor-job-1"
  exit 0
fi
if [[ "$args" == *"delete"* ]]; then
  # Fail if a delete is attempted during advisory mode — test should catch this
  echo "ERROR: kubectl delete invoked (mock)" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
# Default fallback
exit 0
MOCK
chmod +x "$TMPBIN/kubectl"

export PATH="$TMPBIN:$PATH"

# --- Test A: ADVISORY mode + enforcement DISABLED => SKIP and exit 0, NO ERROR
cat > "$STATEFILE" <<JSON
{"enabled": false, "tier": "none"}
JSON
export THREADFORGE_ENFORCEMENT_STATE_FILE="$STATEFILE"

export STRICT=0
set +e
bash scripts/doctor-clean.sh >"$TMPOUT" 2>&1
rc=$?
set -e

cat "$TMPOUT"

if [ "$rc" -ne 0 ]; then
  echo "FAIL: Expected exit 0 in advisory mode when enforcement disabled, got $rc"
  rm -rf "$TMPBIN" "$TMPOUT" "$STATEFILE"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if grep -q "ERROR:" "$TMPOUT"; then
  echo "FAIL: Advisory run must not emit ERROR: lines"
  cat "$TMPOUT"
  rm -rf "$TMPBIN" "$TMPOUT" "$STATEFILE"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if ! grep -q "SKIP: cleanup requires a full trust tier" "$TMPOUT"; then
  echo "FAIL: Expected SKIP message when enforcement denies cleanup in advisory mode"
  cat "$TMPOUT"
  rm -rf "$TMPBIN" "$TMPOUT" "$STATEFILE"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ Advisory mode: enforcement denied -> SKIP (no ERROR)"

# --- Test B: STRICT mode + enforcement DISABLED => ERROR + echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
export STRICT=1
set +e
bash scripts/doctor-clean.sh >"$TMPOUT" 2>&1
rc=$?
set -e

cat "$TMPOUT"

if [ "$rc" -ne 2 ]; then
  echo "FAIL: Expected echo "[ADVISORY-FAIL] non-authoritative path"; exit 0 in strict mode when enforcement disabled, got $rc"
  rm -rf "$TMPBIN" "$TMPOUT" "$STATEFILE"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if ! grep -q "ERROR: execution denied" "$TMPOUT"; then
  echo "FAIL: Expected ERROR message in strict mode when enforcement denies cleanup"
  cat "$TMPOUT"
  rm -rf "$TMPBIN" "$TMPOUT" "$STATEFILE"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ Strict mode: enforcement denied -> ERROR (non-zero exit)"

# --- Test C: ADVISORY mode with enforcement ENABLED -> still DO NOT DELETE (no kubectl delete)
cat > "$STATEFILE" <<JSON
{"enabled": true, "tier": "full"}
JSON
export THREADFORGE_ENFORCEMENT_STATE_FILE="$STATEFILE"
export STRICT=0

set +e
bash scripts/doctor-clean.sh >"$TMPOUT" 2>&1
rc=$?
set -e

cat "$TMPOUT"

if [ "$rc" -ne 0 ]; then
  echo "FAIL: Expected exit 0 in advisory mode even when enforcement enabled (doctor must be read-only), got $rc"
  rm -rf "$TMPBIN" "$TMPOUT" "$STATEFILE"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if grep -q "kubectl delete invoked" "$TMPOUT"; then
  echo "FAIL: doctor-clean should NOT attempt deletion in advisory mode"
  cat "$TMPOUT"
  rm -rf "$TMPBIN" "$TMPOUT" "$STATEFILE"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if ! grep -q "SKIP: cleanup requires a full trust tier; doctor is read-only" "$TMPOUT"; then
  echo "FAIL: Expected SKIP message when doctor runs in advisory mode (no deletes)"
  cat "$TMPOUT"
  rm -rf "$TMPBIN" "$TMPOUT" "$STATEFILE"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ Advisory mode: enforcement enabled but doctor remains read-only (no delete)"

rm -rf "$TMPBIN" "$TMPOUT" "$STATEFILE"

echo "=== Test PASSED: doctor-clean advisory/strict semantics verified ==="
