#!/usr/bin/env bash
# Authority Domain: operator_infra
# requires_identity=true  # trust_tier=full
if ! bash platform/runtime/operator/identity_enforcer.sh --require-full >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires a full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

set -euo pipefail

NS="vault"
STS="vault"
POD="vault-0"

echo "============================================================"
echo "      ENABLE TRANSIT SEAL — FIXED HTTP VERSION"
echo "============================================================"

echo ""
echo "== STEP 1: Ensure transit secret exists =="
kubectl -n $NS get secret vault-transit-token >/dev/null

echo ""
echo "== STEP 2: Apply ConfigMap with transit seal =="
kubectl -n $NS apply -f platform/deploy/infra/vault/templates/configmap.yaml

echo ""
echo "== STEP 3: SCALE STATEFULSET TO ZERO =="
kubectl -n $NS scale statefulset $STS --replicas=0

echo "Waiting for pod to terminate..."
kubectl -n $NS wait --for=delete pod/$POD --timeout=60s || true

echo ""
echo "== STEP 4: WIPE RAFT DATA DIRECTORY =="
PVC="data-vault-0"
if kubectl -n $NS get pvc ${PVC} >/dev/null 2>&1; then
  echo "Deleting PVC ${PVC}..."
  kubectl -n $NS delete pvc ${PVC}
else
  echo "No PVC found; emptyDir means nothing to delete."
fi

echo ""
echo "== STEP 5: SCALE STATEFULSET BACK UP =="
kubectl -n $NS scale statefulset $STS --replicas=1

echo ""
echo "== STEP 6: WAIT FOR POD STARTUP =="
kubectl -n $NS wait --for=condition=Ready pod/$POD --timeout=180s || {
  echo "❌ Vault pod did not become Ready — check logs."
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
}

echo ""
echo "== STEP 7: VALIDATE TRANSIT SEAL =="
kubectl -n $NS exec $POD -- sh -c '
  export VAULT_ADDR=http://127.0.0.1:8200
  vault status
'

echo ""
echo "============================================================"
echo "✨ TRANSIT SEAL ENABLED SUCCESSFULLY"
echo "============================================================"
echo ""
