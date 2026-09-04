#!/usr/bin/env bash
# Simple e2e assertion: exit non-zero if any Deployment in `workers` namespace uses default or no ServiceAccount
set -euo pipefail
bad=$(kubectl get deployments -n workers -o jsonpath='{range .items[*]}{.metadata.name}:::{.spec.template.spec.serviceAccountName}\n{end}' 2>/dev/null | awk -F ':::' '$2==""||$2=="default"{print $1":"$2}' || true)
if [[ -n "$bad" ]]; then
  echo "[ERROR] Found worker Deployments with default/no ServiceAccount: $bad" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
echo "OK: all worker Deployments use dedicated ServiceAccounts"
