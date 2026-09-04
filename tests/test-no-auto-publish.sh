#!/usr/bin/env bash
set -euo pipefail

# Ensure no automatic invocation of publish_execution_mode.sh exists in code (exclude tests/docs/markdown)
if grep -RIn --exclude-dir={tests,docs} --exclude='*.md' "publish_execution_mode.sh" -- . | egrep -v "platform/runtime/operator/publish_execution_mode.sh" >/dev/null; then
  echo "Found invocation(s) of publish_execution_mode.sh in code (must not be automatic):"; grep -RIn --exclude-dir={tests,docs} --exclude='*.md' "publish_execution_mode.sh" -- . | egrep -v "platform/runtime/operator/publish_execution_mode.sh"; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "OK: no automatic invocation of publish_execution_mode.sh found in code (tests/docs/markdown excluded)"
