#!/usr/bin/env bash
# Test: doctor-collector-gate.sh enforces in strict mode
# Proves that when STRICT=1 and no collector pods exist, script exits 2

set -euo pipefail

echo "=== Test: doctor-collector-gate strict enforcement ==="

TMPBIN=$(mktemp -d)
TMPOUT=$(mktemp)

# Mock kubectl to simulate no collector pods
cat > "$TMPBIN/kubectl" <<'MOCK'
#!/usr/bin/env bash
# Return empty list for collector pods (simulates no collectors running)
if [[ "$*" == *"get pods"* ]] && [[ "$*" == *"otel-collector"* ]]; then
  if [[ "$*" == *"--no-headers"* ]]; then
    # Return empty output (no pods)
    exit 0
  elif [[ "$*" == *"-o json"* ]]; then
    echo '{"items":[]}'
    exit 0
  fi
fi
if [[ "$*" == *"logs"* ]]; then
  # No logs (no pods exist)
  exit 0
fi
exit 0
MOCK
chmod +x "$TMPBIN/kubectl"

# Mock git for DRILL_ID evidence
cat > "$TMPBIN/git" <<'MOCKGIT'
#!/usr/bin/env bash
if [ "$1" = "rev-parse" ]; then
  echo "testsha"
  exit 0
fi
exit 0
MOCKGIT
chmod +x "$TMPBIN/git"

export PATH="$TMPBIN:$PATH"
export DRILL_ID="test-strict-enforcement-$(date +%s)"
export STRICT=1

# Test 1: Strict mode with no collectors should echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
set +e
bash scripts/doctor-collector-gate.sh >"$TMPOUT" 2>&1
rc=$?
set -e

cat "$TMPOUT"

if [ "$rc" -ne 2 ]; then
  echo "FAIL: Expected echo "[ADVISORY-FAIL] non-authoritative path"; exit 0 in strict mode with no collectors, got $rc"
  rm -rf "$TMPBIN" "$TMPOUT"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if ! grep -q "FAIL.*No collector pods running.*execution blocked" "$TMPOUT"; then
  echo "FAIL: Expected failure message in output"
  cat "$TMPOUT"
  rm -rf "$TMPBIN" "$TMPOUT"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ Strict mode correctly blocks when no collectors present"

# Test 2: Advisory mode with no collectors should exit 0
export STRICT=0

set +e
bash scripts/doctor-collector-gate.sh >"$TMPOUT" 2>&1
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  echo "FAIL: Expected exit 0 in advisory mode, got $rc"
  cat "$TMPOUT"
  rm -rf "$TMPBIN" "$TMPOUT"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if ! grep -q "ADVISORY.*no collector pods observed" "$TMPOUT"; then
  echo "FAIL: Expected advisory message in output"
  cat "$TMPOUT"
  rm -rf "$TMPBIN" "$TMPOUT"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ Advisory mode correctly allows when no collectors present"

# Test 3: Strict mode with collectors present should exit 0
# Mock kubectl to return 1 collector pod
cat > "$TMPBIN/kubectl" <<'MOCK2'
#!/usr/bin/env bash
if [[ "$*" == *"get pods"* ]] && [[ "$*" == *"otel-collector"* ]]; then
  if [[ "$*" == *"--no-headers"* ]]; then
    echo "otel-collector-0   1/1   Running   0   10m"
    exit 0
  elif [[ "$*" == *"-o json"* ]]; then
    echo '{"items":[{"metadata":{"name":"otel-collector-0"}}]}'
    exit 0
  fi
fi
if [[ "$*" == *"logs"* ]]; then
  echo "collector logs here"
  exit 0
fi
exit 0
MOCK2
chmod +x "$TMPBIN/kubectl"

export STRICT=1

set +e
bash scripts/doctor-collector-gate.sh >"$TMPOUT" 2>&1
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  echo "FAIL: Expected exit 0 in strict mode with collectors present, got $rc"
  cat "$TMPOUT"
  rm -rf "$TMPBIN" "$TMPOUT"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if ! grep -q "PASS.*collector pod(s) running" "$TMPOUT"; then
  echo "FAIL: Expected PASS message in output"
  cat "$TMPOUT"
  rm -rf "$TMPBIN" "$TMPOUT"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ Strict mode correctly passes when collectors present"

rm -rf "$TMPBIN" "$TMPOUT" /tmp/${DRILL_ID}-* || true

echo "=== Test PASSED: doctor-collector-gate strict enforcement verified ==="
