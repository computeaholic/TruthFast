#!/usr/bin/env bash
set -euo pipefail

NS="vault"

echo "🔎 Vault Status:"
kubectl -n $NS exec vault-0 -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status' || true

echo "📁 Token directory:"
kubectl -n $NS exec vault-0 -- sh -c 'ls -l /vault/kms || true'

echo "📄 vault.hcl:"
kubectl -n $NS exec vault-0 -- sh -c 'cat /vault/config/vault.hcl' || true
