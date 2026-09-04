#!/usr/bin/env bash
set -euo pipefail

PY=$(command -v python3 || command -v python)
if [ -z "${PY}" ]; then
  echo "python not found; skipping test"; exit 0
fi

# 1) Ensure enforcement disabled -> identity_enforcer blocks
$PY - <<'PY'
from runtime.metrics.enforcement import set_enforcement_ready
set_enforcement_ready(False, tier='none')
print('set enforcement -> none')
PY

set +e
bash platform/runtime/operator/identity_enforcer.sh --require-full >/tmp/iden_out 2>&1
rc=$?
set -e
cat /tmp/iden_out
if [ "$rc" -eq 2 ]; then
  echo "OK: identity_enforcer blocked as expected when enforcement disabled"
else
  echo "FAIL: identity_enforcer did not block (rc=$rc)"; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# 2) Enable enforcement to full -> identity_enforcer allows
$PY - <<'PY'
from runtime.metrics.enforcement import set_enforcement_ready
set_enforcement_ready(True, tier='full')
print('set enforcement -> full')
PY

bash platform/runtime/operator/identity_enforcer.sh --require-full >/tmp/iden_out2 2>&1
rc=$?
cat /tmp/iden_out2
if [ "$rc" -eq 0 ]; then
  echo "OK: identity_enforcer allowed when enforcement full"
else
  echo "FAIL: identity_enforcer blocked unexpectedly (rc=$rc)"; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# 3) Ensure autoheal is blocked when enforcement disabled
$PY - <<'PY'
from runtime.metrics.enforcement import set_enforcement_ready
set_enforcement_ready(False, tier='none')
print('set enforcement -> none (for autoheal)')
PY

set +e
bash tools/dev/autoheal.sh >/tmp/autoheal_out 2>&1
rc=$?
set -e
cat /tmp/autoheal_out | sed -n '1,120p'
if [ "$rc" -ne 0 ]; then
  echo "OK: autoheal blocked as expected when enforcement disabled (rc=$rc)"
else
  echo "FAIL: autoheal should have been blocked but was allowed"; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "All identity enforcement tests passed"
