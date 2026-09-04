#!/usr/bin/env bash
# requires_identity=true  # trust_tier=full
# Authority Domain: operator_infra
if ! bash platform/runtime/operator/identity_enforcer.sh --require-full >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires a full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

set -euo pipefail

NS="vault"

echo "🧹 Cleaning Vault Identity Server..."

kubectl -n $NS delete statefulset vault --ignore-not-found --force --grace-period=0
kubectl -n $NS delete pod vault-0 --ignore-not-found --force --grace-period=0
kubectl -n $NS delete secret vault-transit-token --ignore-not-found
kubectl -n $NS delete configmap vault-hcl --ignore-not-found

echo "🚀 Reinstalling clean Vault (Shamir mode)..."
helm upgrade --install vault platform/deploy/infra/vault -n $NS

echo "⏳ Waiting for Vault pod..."
kubectl -n $NS wait pod/vault-0 --for=condition=Ready --timeout=120s

echo "✨ Vault baseline ready (no transit seal)."
