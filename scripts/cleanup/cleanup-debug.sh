#!/usr/bin/env bash
# Authority Domain: confirm_gated
# requires_identity=true  # trust_tier=full
if ! bash platform/runtime/operator/identity_enforcer.sh --require-full >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires a full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

set -euo pipefail

# cleanup-debug.sh
# Safely delete leftover kubectl-debug pods (node-debugger-*) in kube-system.

# Usage:
#  - Dry run (default): ./cleanup-debug.sh
#  - Confirm deletion: CONFIRM=true ./cleanup-debug.sh

CONFIRM=${CONFIRM:-false}
NAMESPACE=${NAMESPACE:-kube-system}
LABEL_SELECTOR='app.kubernetes.io/managed-by=kubectl-debug'

jq_filter='[.items[] | select((.metadata.ownerReferences // null) == null) | {namespace: .metadata.namespace, name: .metadata.name, labels: .metadata.labels}]'

echo "Gathering kubectl-debug candidate pods in namespace $NAMESPACE..."
raw=$(kubectl -n "$NAMESPACE" get pods -l "$LABEL_SELECTOR" -o json)

candidates_count=$(echo "$raw" | jq -r "$jq_filter | length")
if [ "$candidates_count" -eq 0 ]; then
  echo "No kubectl-debug candidate pods found."
  exit 0
fi

candidates=$(echo "$raw" | jq -c "$jq_filter[]")

filtered=()
while IFS= read -r pod; do
  name=$(echo "$pod" | jq -r .name)
  if [[ "$name" != node-debugger-* ]]; then
    echo "Skipping $name (does not match node-debugger-*)"
    continue
  fi
  filtered+=("$pod")
done <<< "$(echo "$candidates")"

if [ ${#filtered[@]} -eq 0 ]; then
  echo "No node-debugger-* pods found after filtering."
  exit 0
fi

echo
echo "Candidates (dry-run):"
for pod in "${filtered[@]}"; do
  ns=$(echo "$pod" | jq -r .namespace)
  name=$(echo "$pod" | jq -r .name)
  echo "  - $ns/$name"
done

if [ "$CONFIRM" != "true" ]; then
  echo
  echo "Dry-run only. To delete the listed pods, re-run with CONFIRM=true."
  echo "Example: CONFIRM=true ./cleanup-debug.sh"
  exit 0
fi

for pod in "${filtered[@]}"; do
  ns=$(echo "$pod" | jq -r .namespace)
  name=$(echo "$pod" | jq -r .name)
  echo "Deleting pod $ns/$name ..."
  kubectl -n "$ns" delete pod "$name" --ignore-not-found=true
done

echo "Deletion complete."
