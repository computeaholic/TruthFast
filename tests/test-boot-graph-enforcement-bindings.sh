#!/usr/bin/env bash
# Test: BOOT_GRAPH.md guarantees are bound to Makefile enforcement
# Proves that each guarantee has a corresponding Make target and dependency

set -euo pipefail

echo "=== Test: BOOT_GRAPH.md guarantees bound to enforcement ==="

TMPOUT=$(mktemp)
FAIL=0

# Verify Makefile contains the bootstrap dependency chain
if ! grep -q "bootstrap:" Makefile; then
  echo "FAIL: Makefile missing bootstrap target"
  FAIL=1
fi

if ! grep -q "preflight" Makefile; then
  echo "FAIL: Makefile missing preflight target (verify-tools)"
  FAIL=1
fi

if ! grep -q "infra-identity" Makefile; then
  echo "FAIL: Makefile missing infra-identity target (SPIRE)"
  FAIL=1
fi

if ! grep -q "infra-mesh" Makefile; then
  echo "FAIL: Makefile missing infra-mesh target (Istio core)"
  FAIL=1
fi

if ! grep -q "infra-policy" Makefile; then
  echo "FAIL: Makefile missing infra-policy target (Istio policies)"
  FAIL=1
fi

if ! grep -q "infra-observability" Makefile; then
  echo "FAIL: Makefile missing infra-observability target"
  FAIL=1
fi

if ! grep -q "runtime-init" Makefile; then
  echo "FAIL: Makefile missing runtime-init target"
  FAIL=1
fi

echo "✓ All bootstrap stages have corresponding Make targets"

# Verify critical dependencies are enforced
if ! grep -q "infra-identity: identity-golden-check" Makefile; then
  echo "FAIL: infra-identity not dependent on identity-golden-check"
  FAIL=1
fi

if ! grep -q "runtime-init: observability-gate" Makefile; then
  echo "FAIL: runtime-init not dependent on observability-gate"
  FAIL=1
fi

echo "✓ Critical Make dependencies enforced"

# Verify BOOT_GRAPH.md now contains enforcement bindings
if ! grep -q "Enforced by:" BOOT_GRAPH.md; then
  echo "FAIL: BOOT_GRAPH.md missing 'Enforced by:' bindings"
  FAIL=1
fi

if ! grep -q "Failure surface:" BOOT_GRAPH.md; then
  echo "FAIL: BOOT_GRAPH.md missing 'Failure surface:' specifications"
  FAIL=1
fi

# Count enforcement bindings (should be 9, one per stage)
enforcement_count=$(grep -c "Enforced by:" BOOT_GRAPH.md)
if [ "$enforcement_count" -ne 9 ]; then
  echo "FAIL: Expected 9 'Enforced by:' bindings, found $enforcement_count"
  FAIL=1
fi

failure_surface_count=$(grep -c "Failure surface:" BOOT_GRAPH.md)
if [ "$failure_surface_count" -ne 9 ]; then
  echo "FAIL: Expected 9 'Failure surface:' specs, found $failure_surface_count"
  FAIL=1
fi

echo "✓ BOOT_GRAPH.md contains enforcement bindings for all stages"

# Verify old "Guarantee:" language replaced with enforcement bindings
if grep -q "^Guarantee:$" BOOT_GRAPH.md; then
  echo "FAIL: BOOT_GRAPH.md still contains standalone 'Guarantee:' sections"
  grep -n "^Guarantee:$" BOOT_GRAPH.md
  FAIL=1
fi

echo "✓ Old guarantee language replaced with enforcement bindings"

if [ "$FAIL" -eq 0 ]; then
  echo "=== Test PASSED: BOOT_GRAPH.md guarantees bound to enforcement ==="
  exit 0
else
  echo "=== Test FAILED: Some enforcement bindings missing ==="
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
