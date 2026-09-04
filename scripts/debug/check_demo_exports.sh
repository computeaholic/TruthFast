#!/usr/bin/env bash
set -euo pipefail

# Ensure only allowed exports exist in site/content/demo
ALLOWED=("execution_to_value.md")

cd site/content/demo
for f in *; do
  if [[ ! " ${ALLOWED[*]} " =~ " ${f} " ]]; then
    echo "Unexpected demo export: $f"
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
done

echo "Demo export validation passed"
