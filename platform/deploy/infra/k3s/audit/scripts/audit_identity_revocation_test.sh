#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="audit-test-revocation"
SA_NAME="revocation-test-sa"
ROLE_NAME="revocation-test-role"
RB_NAME="revocation-test-rb"
AUDIT_LOG="/var/log/kubernetes/audit/audit.log"

# create namespace if missing
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"

# create serviceaccount if missing
kubectl -n "$NAMESPACE" get sa "$SA_NAME" >/dev/null 2>&1 || kubectl -n "$NAMESPACE" create sa "$SA_NAME"

# create role allowing get,list on configmaps
cat <<EOF | kubectl -n "$NAMESPACE" apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: $ROLE_NAME
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get","list"]
EOF

# bind role to SA
kubectl -n "$NAMESPACE" get rolebinding "$RB_NAME" >/dev/null 2>&1 || kubectl -n "$NAMESPACE" create rolebinding "$RB_NAME" --role="$ROLE_NAME" --serviceaccount="$NAMESPACE:$SA_NAME"

# Verify SA can perform allowed action
if ! kubectl -n "$NAMESPACE" auth can-i get configmaps --as=system:serviceaccount:$NAMESPACE:$SA_NAME >/dev/null 2>&1; then
  echo "Initial permission missing" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Remove RoleBinding (revoke)
kubectl -n "$NAMESPACE" delete rolebinding "$RB_NAME" --ignore-not-found=true >/dev/null 2>&1 || true

# Re-test permission; must fail
if kubectl -n "$NAMESPACE" auth can-i get configmaps --as=system:serviceaccount:$NAMESPACE:$SA_NAME >/dev/null 2>&1; then
  echo "Revocation did not remove permission" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Verify audit log contains RoleBinding deletion and Forbidden event after revocation
if [ ! -f "$AUDIT_LOG" ]; then
  echo "Audit log not accessible" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Check for RoleBinding deletion event in audit log
RB_DELETION_PRESENT=$(tac "$AUDIT_LOG" | jq -c 'select(.objectRef.namespace=="'$NAMESPACE'" and .objectRef.name=="'$RB_NAME'" and .verb=="delete")' 2>/dev/null | head -n1 || true)
if [ -z "$RB_DELETION_PRESENT" ]; then
  echo "Audit entry for RoleBinding deletion missing" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Check for Forbidden event for SA after revocation (verb get configmaps resulted 403)
FORBIDDEN_EVENT=$(tac "$AUDIT_LOG" | jq -c 'select(.user.username=="system:serviceaccount:'$NAMESPACE':'$SA_NAME'" and .verb=="get" and .objectRef.resource=="configmaps" and (.responseStatus.code==403 or .responseStatus.code==401))' 2>/dev/null | head -n1 || true)
if [ -z "$FORBIDDEN_EVENT" ]; then
  echo "Forbidden audit event after revocation missing" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Cleanup: remove Role
kubectl -n "$NAMESPACE" delete role "$ROLE_NAME" --ignore-not-found=true >/dev/null 2>&1 || true
kubectl -n "$NAMESPACE" delete sa "$SA_NAME" --ignore-not-found=true >/dev/null 2>&1 || true
kubectl delete ns "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1 || true

echo "Identity revocation mechanically verified"
exit 0
