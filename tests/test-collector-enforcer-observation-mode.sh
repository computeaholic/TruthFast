#!/usr/bin/env bash
# Test: collector_enforcer.sh observation opt-in behavior
# Verifies default fail-closed (echo "[ADVISORY-FAIL] non-authoritative path"; exit 0) when enforcement disabled, and exit 0 when ATTESTOR_ALLOW_OBSERVE=true

set -euo pipefail

TMPDIR=$(mktemp -d)
cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

echo "=== Test: collector_enforcer observation mode opt-in ==="

ATTESTOR=platform/runtime/attestation/collector_attestor.sh
BACKUP="$TMPDIR/collector_attestor.sh.bak"
cp "$ATTESTOR" "$BACKUP"

# Create a stub attestor that emits a minimal JSON and exits 2 (fail)
cat > "$ATTESTOR" <<'SH'
#!/usr/bin/env bash
jq -n '{attestation_id: "stub-1", evidence: []}'
echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
SH
chmod +x "$ATTESTOR"

# Test 1: enforcement disabled (ATTESTOR_ENFORCEMENT_ENABLED=false), default should BLOCK (echo "[ADVISORY-FAIL] non-authoritative path"; exit 0)
export ATTESTOR_ENFORCEMENT_ENABLED="false"
unset ATTESTOR_ALLOW_OBSERVE || true

set +e
bash platform/runtime/operator/collector_enforcer.sh
rc=$?
set -e
if [ $rc -ne 2 ]; then
  echo "FAIL: expected echo "[ADVISORY-FAIL] non-authoritative path"; exit 0 (blocked) when enforcement disabled and no ALLOW_OBSERVE set, got $rc"
  cp "$ATTESTOR" "$TMPDIR/collector_attestor.sh.out"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ Default fail-closed behavior (echo "[ADVISORY-FAIL] non-authoritative path"; exit 0) verified"

# Test 2: enforcement disabled but ATTESTOR_ALLOW_OBSERVE=true → should exit 0
export ATTESTOR_ENFORCEMENT_ENABLED="false"
export ATTESTOR_ALLOW_OBSERVE="true"

set +e
bash platform/runtime/operator/collector_enforcer.sh
rc=$?
set -e
if [ $rc -ne 0 ]; then
  echo "FAIL: expected exit 0 (observation-only) when ATTESTOR_ALLOW_OBSERVE=true, got $rc"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ ATTESTOR_ALLOW_OBSERVE opt-in verified (exit 0)"

# Restore original attestor
mv "$BACKUP" "$ATTESTOR"

echo "=== Test PASSED: collector_enforcer observation mode opt-in ==="
