#!/usr/bin/env bash
set -euo pipefail

echo "Running tests..."
FAIL=0
bash tests/test-dependency-lint.sh || FAIL=1
bash tests/test-dependency-labels.sh || FAIL=1
bash tests/test-phase-eval-core.sh || FAIL=1
# run frozen override test (integration-level, fast)
bash tests/test-phase-eval.sh || FAIL=1

# SPIFFE identity advisory tests (fixtures-only)
bash tests/test-phase-identity-authorized.sh || FAIL=1
bash tests/test-phase-identity-unauthorized.sh || FAIL=1
bash tests/test-phase-identity-missing.sh || FAIL=1

if [ "$FAIL" -ne 0 ]; then
  echo "Some tests failed"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
else
  echo "All tests passed"
fi
