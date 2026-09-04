#!/usr/bin/env bash
# Authority Domain: operator_infra
# requires_identity=true  # trust_tier=full
if ! bash platform/runtime/operator/identity_enforcer.sh --require-full >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires a full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

set -euo pipefail

NS="vault"

echo "🛑 Disabling transit auto-unseal..."

kubectl -n $NS delete secret vault-transit-token --ignore-not-found

echo "🧽 Removing seal block..."
kubectl -n $NS get configmap vault-hcl -o json | \
  jq -r '.data["vault.hcl"]' | \
  sed '/seal "transit"/,/}/d' > /tmp/vault.hcl.noseal

kubectl -n $NS delete configmap vault-hcl --ignore-not-found
kubectl -n $NS create configmap vault-hcl --from-file=vault.hcl=/tmp/vault.hcl.noseal

echo "♻ Restarting Vault..."
kubectl -n $NS delete pod vault-0 --force --grace-period=0

kubectl -n $NS wait pod/vault-0 --for=condition=Ready --timeout=120s
kubectl -n $NS exec vault-0 -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status'
