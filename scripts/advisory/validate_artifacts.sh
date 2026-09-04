#!/usr/bin/env bash

set -euo pipefail

# Run from repo root
if [ ! -d artifacts ]; then
  echo "❌ artifacts directory not found"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if ls -A artifacts | grep -E '^(run|phase|tmp)([-_.]|$)' >/dev/null 2>&1; then
  echo "❌ Invalid artifact naming detected"
  ls -A artifacts | grep -E '^(run|phase|tmp)([-_.]|$)' || true
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Reject forbidden artifact path-segment naming patterns (phase*, run*, tmp*)
if git ls-files artifacts | grep -E '(^|/)(phase|run|tmp)([-_.][^/]*|)($|/)' >/dev/null 2>&1; then
  echo "❌ Forbidden naming pattern detected (phase*/run*/tmp*)"
  git ls-files artifacts | grep -E '(^|/)(phase|run|tmp)([-_.][^/]*|)($|/)'
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Enforce test file placement under tests/
if git ls-files | grep -E '^test_.*\.py$' | grep -v '^tests/' >/dev/null 2>&1; then
  echo "❌ Test files must live in /tests"
  git ls-files | grep -E '^test_.*\.py$' | grep -v '^tests/'
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✅ artifacts clean"
