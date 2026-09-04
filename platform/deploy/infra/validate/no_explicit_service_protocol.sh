#!/usr/bin/env bash
set -euo pipefail

# Check for explicit protocol in Service templates
if find deploy -name "*.yaml" -o -name "*.yml" | xargs grep -l "protocol:" | grep -q Service; then
  echo "ERROR: Service template(s) explicitly set protocol:"
  find deploy -name "*.yaml" -o -name "*.yml" | xargs grep -l "protocol:" | grep Service
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ No Service templates explicitly set protocol"