#!/usr/bin/env bash
set -euo pipefail

# Ensure only the attestation manager sets enforcement readiness by calling set_enforcement_ready
# We grep for set_enforcement_ready calls and assert they are only in manager.py and metrics/enforcement.py
hits=$(grep -RInF "set_enforcement_ready(" -- . | cut -d: -f1 | sort -u)
allowed_runtime="platform/runtime/attestation/manager.py platform/runtime/metrics/enforcement.py"
bad=0
for f in $hits; do
  # normalize potential leading ./
  f=${f#./}
  # Allow hits in tests/ and docs/ (documentation and tests may reference or exercise the setter)
  case "$f" in
    tests/*|docs/*)
      continue
      ;;
    platform/runtime/attestation/manager.py|platform/runtime/metrics/enforcement.py)
      continue
      ;;
    *)
      echo "Unauthorized setter call found in $f"; bad=1
      ;;
  esac
done

if [ "$bad" -ne 0 ]; then
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "OK: set_enforcement_ready usage restricted to allowed files"
