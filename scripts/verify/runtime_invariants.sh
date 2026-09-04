#!/usr/bin/env bash
set -euo pipefail

# Runtime invariants sanity checks (observe-only)
# - Run the non-integration test suite as a sanity check (read-only)
# - Exits non-zero if tests fail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENV_PYTHON="$REPO_ROOT/.venv/bin/python"

echo "[runtime_invariants] Running non-integration test suite (sanity check)."
if [ ! -x "$VENV_PYTHON" ]; then
  echo "[runtime_invariants] ERROR: virtualenv python not found at $VENV_PYTHON" >&2
  exit 10
fi

# Run tests; allow pytest to return non-zero on failing tests
"$VENV_PYTHON" -m pytest -q -m "not integration" -p no:cacheprovider --rootdir="$REPO_ROOT"
PY_EXIT=$?
if [ "$PY_EXIT" -ne 0 ]; then
  echo "[runtime_invariants] ERROR: non-integration tests failed (exit $PY_EXIT)." >&2
  exit 2
fi

echo "[runtime_invariants] Summary: non-integration tests passed."
exit 0
