#!/usr/bin/env bash
# Authority Domain: confirm_gated
# requires_identity=true  # trust_tier=full
if ! bash platform/runtime/operator/identity_enforcer.sh --require-full >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires a full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

set -euo pipefail

# cleanup-tests.sh
# Safely delete ephemeral test/debug pods labeled for manual cleanup.

# Usage:
#  - Dry run (default): ./cleanup-tests.sh
#  - Confirm deletion: CONFIRM=true ./cleanup-tests.sh
#  - Optionally scope to a namespace: NAMESPACE=observability ./cleanup-tests.sh
#
# Security & safety rules:
#  - Selects pods with label: threadforge.dev/ephemeral=true
#  - AND threadforge.dev/purpose in (test,debug,doctor-probe)
#  - Excludes pods with ownerReferences (i.e., managed by controllers)
#  - Excludes critical namespaces unless the pod has label threadforge.dev/allow-critical=true
#  - Supports an allowlist file at scripts/cleanup/cleanup-tests.allowlist (namespace/name per-line)
#  - Requires CONFIRM=true to actually delete pods

PURPOSE=${PURPOSE:-"test,debug"}
# Always include doctor-probe by default
if ! echo "$PURPOSE" | grep -q "doctor-probe"; then
  PURPOSE="$PURPOSE,doctor-probe"
fi
LABEL_SELECTOR="threadforge.dev/ephemeral=true,threadforge.dev/purpose in ($PURPOSE)"
CONFIRM=${CONFIRM:-false}
NAMESPACE=${NAMESPACE:-}

# Critical namespaces to exclude unless explicitly labeled
CRITICAL_NS=("spire-system" "istio-system" "kube-system" "loki" "minio" "observability" "threadforge-system")

jq_filter='[.items[] | select((.metadata.ownerReferences // null) == null) | {namespace: .metadata.namespace, name: .metadata.name, labels: .metadata.labels}]'

if [ -n "$NAMESPACE" ]; then
  KUBECTL_GET=(kubectl -n "$NAMESPACE" get pods -l "$LABEL_SELECTOR" -o json)
else
  KUBECTL_GET=(kubectl get pods -A -l "$LABEL_SELECTOR" -o json)
fi

echo "Gathering candidate pods (selector: $LABEL_SELECTOR) ..."
raw=$("${KUBECTL_GET[@]}")

candidates_count=$(echo "$raw" | jq -r "$jq_filter | length")

if [ "$candidates_count" -eq 0 ]; then
  echo "No candidate pods found (matching label and not owned by controllers)."
  exit 0
fi

# Filter out critical namespaces unless pod has explicit allow label
candidates=$(echo "$raw" | jq -c "$jq_filter[]")
filtered=()
while IFS= read -r pod; do
  ns=$(echo "$pod" | jq -r .namespace)
  name=$(echo "$pod" | jq -r .name)
  allow_critical=$(echo "$pod" | jq -r '.labels["threadforge.dev/allow-critical"] // "false"')
  is_critical=false
  for cns in "${CRITICAL_NS[@]}"; do
    if [ "$ns" = "$cns" ]; then is_critical=true; break; fi
  done
  if [ "$is_critical" = true ] && [ "$allow_critical" != "true" ]; then
    echo "Skipping $ns/$name (critical namespace; requires label threadforge.dev/allow-critical=true)"
    continue
  fi
  filtered+=("$pod")
done <<< "$(echo "$candidates")"

# Apply allowlist if present (lines: namespace/name)
ALLOWLIST_FILE="scripts/cleanup/cleanup-tests.allowlist"
allowlist=()
if [ -f "$ALLOWLIST_FILE" ]; then
  while IFS= read -r l; do
    l_trim=$(echo "$l" | sed -e 's/^\s*//' -e 's/\s*$//')
    [ -z "$l_trim" ] && continue
    allowlist+=("$l_trim")
  done < "$ALLOWLIST_FILE"
fi

# Filter out allowlisted pods
final_filtered=()
for pod in "${filtered[@]}"; do
  ns=$(echo "$pod" | jq -r .namespace)
  name=$(echo "$pod" | jq -r .name)
  full="$ns/$name"
  skip=false
  for a in "${allowlist[@]}"; do
    if [ "$a" = "$full" ]; then skip=true; break; fi
  done
  if [ "$skip" = true ]; then
    echo "Skipping allowlisted $full"
    continue
  fi
  final_filtered+=("$pod")
done

if [ ${#final_filtered[@]} -eq 0 ]; then
  echo "No candidate pods remain after filtering critical namespaces, ownerReferences, and allowlist."
  exit 0
fi

# Replace use of 'filtered' below with 'final_filtered'

echo
echo "Candidates (dry-run):"
for pod in "${final_filtered[@]}"; do
  ns=$(echo "$pod" | jq -r .namespace)
  name=$(echo "$pod" | jq -r .name)
  echo "  - $ns/$name"
done

if [ "$CONFIRM" != "true" ]; then
  echo
  echo "Dry-run only. To delete the listed pods, re-run with CONFIRM=true."
  echo "Example: CONFIRM=true ./cleanup-tests.sh"
  exit 0
fi

# Confirmed: delete pods one-by-one (no parallelism) with explicit kubectl delete
for pod in "${final_filtered[@]}"; do
  ns=$(echo "$pod" | jq -r .namespace)
  name=$(echo "$pod" | jq -r .name)
  echo "Deleting pod $ns/$name ..."
  kubectl -n "$ns" delete pod "$name" --ignore-not-found=true
done

echo "Deletion complete."
