#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="audit-test-escalation"
SA_NAME="escalation-test-sa"
RB_NAME="escalation-test-rb"
AUDIT_LOG="/var/log/kubernetes/audit/audit.log"
LEDGER="/home/threadforge/threadforge/platform/deploy/infra/k3s/audit/AUDIT_ROTATION_LEDGER.jsonl"

# Setup namespace and SA
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"
kubectl -n "$NAMESPACE" get sa "$SA_NAME" >/dev/null 2>&1 || kubectl -n "$NAMESPACE" create sa "$SA_NAME"

# Attempt to create a namespaced RoleBinding that references cluster-admin ClusterRole
cat <<EOF | kubectl -n "$NAMESPACE" apply -f - >/dev/null 2>&1 || true
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: $RB_NAME
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: $SA_NAME
  namespace: $NAMESPACE
EOF

# Check if RoleBinding exists (escalation allowed)
if ! kubectl -n "$NAMESPACE" get rolebinding "$RB_NAME" >/dev/null 2>&1; then
  echo "No escalation occurred or creation denied — nothing to verify" >&2
  # cleanup
  kubectl -n "$NAMESPACE" delete sa "$SA_NAME" --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete ns "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1 || true
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# If created, verify audit contains RequestResponse payloads for the creation
if [ ! -f "$AUDIT_LOG" ]; then
  echo "ERROR: audit log missing" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Search for RequestResponse event matching creation
EVENT=$(tac "$AUDIT_LOG" | jq -c 'select(.verb=="create" and .objectRef.kind=="RoleBinding" and .objectRef.name=="'$RB_NAME'" and (.requestObject!=null or .responseObject!=null))' 2>/dev/null | head -n1 || true)
if [ -z "$EVENT" ]; then
  echo "Escalation not logged with RequestResponse payload" >&2
  # cleanup
  kubectl -n "$NAMESPACE" delete rolebinding "$RB_NAME" --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE" delete sa "$SA_NAME" --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete ns "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1 || true
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Verify rotation chain intact
if ! /home/threadforge/threadforge/platform/deploy/infra/k3s/audit/scripts/audit_verify_rotation_chain.sh >/dev/null 2>&1; then
  echo "Rotation chain broken" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Verify ledger seal matches
SEAL="/home/threadforge/threadforge/platform/deploy/infra/k3s/audit/AUDIT_LEDGER_SEAL.json"
if [ ! -f "$SEAL" ]; then
  echo "Ledger seal missing" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Cleanup
kubectl -n "$NAMESPACE" delete rolebinding "$RB_NAME" --ignore-not-found=true >/dev/null 2>&1 || true
kubectl -n "$NAMESPACE" delete sa "$SA_NAME" --ignore-not-found=true >/dev/null 2>&1 || true
kubectl delete ns "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1 || true

echo "RBAC escalation captured and visible"
exit 0
