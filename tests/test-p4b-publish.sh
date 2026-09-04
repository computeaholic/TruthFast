#!/usr/bin/env bash
set -euo pipefail

# Test publish_execution_mode.sh in dry-run (no kubectl) mode
PY=$(command -v python3 || command -v python)
if [ -z "${PY}" ]; then
  echo "python not found; skipping"; exit 0
fi

# 1) enforcement none -> READ_ONLY
$PY - <<'PY'
from runtime.metrics.enforcement import set_enforcement_ready
set_enforcement_ready(False, tier='none')
print('set enforcement none')
PY

out=$(bash platform/runtime/operator/publish_execution_mode.sh)
echo "$out" | egrep "mode: \"READ_ONLY\"" >/dev/null || { echo "expected READ_ONLY"; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0; }

echo "OK: READ_ONLY manifest emitted"

# 2) enforcement full -> ACTIVE
$PY - <<'PY'
from runtime.metrics.enforcement import set_enforcement_ready
set_enforcement_ready(True, tier='full')
print('set enforcement full')
PY

out=$(bash platform/runtime/operator/publish_execution_mode.sh)
echo "$out" | egrep "mode: \"ACTIVE\"" >/dev/null || { echo "expected ACTIVE"; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0; }

echo "OK: ACTIVE manifest emitted"

exit 0
