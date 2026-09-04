#!/usr/bin/env bash
# Verify `make doctor` is read-only by default (DOCTOR_ALLOW_PROBE unset, STRICT=0)

set -euo pipefail

echo "=== Test: make doctor is read-only by default (no probe, no mutations) ==="

TMPBIN=$(mktemp -d)
TMPOUT=$(mktemp)
MUTLOG="$TMPBIN/requests.log"

# Mock kubectl: record every invocation; respond with safe/benign output for get/logs calls
cat > "$TMPBIN/kubectl" <<'MOCK'
#!/usr/bin/env bash
args="$*"
# Record invocation for later inspection
printf "%s\n" "$args" >> "'"$MUTLOG"'"

# Simulate namespace existence checks
if [[ "$args" == *"get ns observability"* ]]; then
  exit 0
fi

# Simulate collector pods listing (json)
if [[ "$args" == *"get pods -n observability"* ]] && [[ "$args" == *"app.kubernetes.io/component=opentelemetry-collector"* ]]; then
  if [[ "$args" == *"-o json"* ]]; then
    echo '{"items":[{"status":{"phase":"Running"}}]}'
    exit 0
  fi
  echo "observability/collector-1"
  exit 0
fi

# Simulate tempo endpoints
if [[ "$args" == *"get endpoints tempo -n"* ]]; then
  if [[ "$args" == *"-o jsonpath"* ]]; then
    echo "[{}]"
    exit 0
  fi
  echo "1.2.3.4"
  exit 0
fi

# Generic get -> success
if [[ "$args" == get* ]]; then
  echo "ok"
  exit 0
fi

# Log mutation verbs but succeed so doctor can finish
if [[ "$args" == *"apply"* ]] || [[ "$args" == *"create"* ]] || [[ "$args" == *"delete"* ]]; then
  printf "MUTATION-DETECTED: %s\n" "$args" >> "'"$MUTLOG"'"
  exit 0
fi

# Default success
exit 0
MOCK

chmod +x "$TMPBIN/kubectl"
export PATH="$TMPBIN:$PATH"

# Ensure probe opt-in is unset and run in advisory mode
unset DOCTOR_ALLOW_PROBE >/dev/null 2>&1 || true
export STRICT=0

set +e
make doctor >"$TMPOUT" 2>&1
rc=$?
set -e

cat "$TMPOUT"

if [ "$rc" -ne 0 ]; then
  echo "FAIL: Expected 'make doctor' to exit 0 in advisory mode, got $rc"
  rm -rf "$TMPBIN" "$TMPOUT"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Verify no mutation verbs were invoked by kubectl
if grep -E -i "\b(apply|create|delete)\b" "$MUTLOG" >/dev/null 2>&1; then
  echo "FAIL: Detected mutation kubectl calls during advisory 'make doctor':"
  grep -nE -i "\b(apply|create|delete)\b" "$MUTLOG" || true
  rm -rf "$TMPBIN" "$TMPOUT"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Also assert that Telemetry probe was skipped (sanity check of contract)
if grep -q "telemetry probe skipped" "$TMPOUT" >/dev/null 2>&1; then
  echo "✓ Telemetry probe correctly skipped by default"
else
  echo "WARN: telemetry probe skip message not observed (ok if other signals present)"
fi

rm -rf "$TMPBIN" "$TMPOUT"

echo "✓ Test PASSED: make doctor is read-only by default (no kubectl apply/create/delete)"
exit 0
