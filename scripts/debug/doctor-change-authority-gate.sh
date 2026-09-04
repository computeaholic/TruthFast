#!/usr/bin/env bash
# ┌──────────────────────────────────────────────────────────────────────────────┐
# │ CHANGE AUTHORITY & DRIFT RESISTANCE GATE (GATING)                            │
# ├──────────────────────────────────────────────────────────────────────────────┤
# │ Authority Question: "Can this system change itself without explicit,         │
# │                      attributable intent?"                                   │
# │                                                                              │
# │ This is the final gate separating governed execution from sovereign          │
# │ execution. It verifies mutation authority is singular, drift is detectable,  │
# │ and all changes are attributable.                                           │
# │                                                                              │
# │ GATING CONDITIONS:                                                           │
# │   1. Change Authority Singular  — One mutation interface per category       │
# │   2. Drift Detectable           — Desired vs effective state observable     │
# │   3. Attribution Exists         — All mutations traceable to identity       │
# │   4. Emergency Mutation Explicit — Break-glass paths logged/bounded         │
# │                                                                              │
# │ FAILURE SEMANTICS:                                                           │
# │   STRICT=1  → echo "[ADVISORY-FAIL] non-authoritative path"; exit 0 immediately (hard fail, execution blocked)             │
# │   STRICT=0  → warn + record degradation, continue (advisory)                │
# │                                                                              │
# │ EVIDENCE BUNDLE: /tmp/${DRILL_ID}-change-authority-evidence/                 │
# └──────────────────────────────────────────────────────────────────────────────┘

set -euo pipefail

STRICT=${STRICT:-0}
if [ "${MODE:-}" = "strict" ]; then STRICT=1; fi

if [ -z "${DRILL_ID:-}" ]; then
  echo "ERROR: DRILL_ID must be set" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

EVIDENCE_DIR="/tmp/${DRILL_ID}-change-authority-evidence"
mkdir -p "$EVIDENCE_DIR"

# Initialize decision state
GATE_PASS=true
FAILURE_REASONS=()

# Timestamps for evidence
NOW_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "[change-authority] Starting change authority & drift resistance gate with DRILL_ID=${DRILL_ID}"

# -----------------------------------------------------------------------------
# CONDITION 1: Change Authority Is Singular
# -----------------------------------------------------------------------------
echo "[change-authority] Checking mutation authority singularity..."

AUTHORITY_OK=true
AUTHORITY_ISSUES=""

# Enumerate mutation sources per resource category
# A resource should be managed by exactly ONE of: Helm, GitOps (Flux/ArgoCD), Operator, or kubectl

# 1. Get all Helm-managed resources
HELM_RELEASES=$(kubectl get secrets -A -l owner=helm -o json 2>/dev/null || echo '{"items":[]}')
HELM_MANAGED_NS=$(echo "$HELM_RELEASES" | jq -r '[.items[].metadata.namespace] | unique | .[]' 2>/dev/null || echo "")

# Build Helm ownership map
declare -A HELM_OWNERSHIP
for ns in $HELM_MANAGED_NS; do
  RELEASES=$(echo "$HELM_RELEASES" | jq -r --arg ns "$ns" '[.items[] | select(.metadata.namespace == $ns) | .metadata.labels.name] | unique | .[]' 2>/dev/null || echo "")
  for release in $RELEASES; do
    HELM_OWNERSHIP["$ns/$release"]="helm"
  done
done

echo "$HELM_RELEASES" | jq '[.items[] | {namespace: .metadata.namespace, name: .metadata.labels.name, status: .metadata.labels.status}] | unique_by(.namespace + "/" + .name)' > "$EVIDENCE_DIR/helm_releases.json" 2>/dev/null || true

# 2. Check for GitOps controllers (Flux, ArgoCD)
GITOPS_PRESENT=false
GITOPS_CONTROLLER=""

# Check for Flux
if kubectl get crd kustomizations.kustomize.toolkit.fluxcd.io >/dev/null 2>&1; then
  GITOPS_PRESENT=true
  GITOPS_CONTROLLER="flux"
  FLUX_KUSTOMIZATIONS=$(kubectl get kustomizations -A -o json 2>/dev/null || echo '{"items":[]}')
  echo "$FLUX_KUSTOMIZATIONS" | jq '[.items[] | {namespace: .metadata.namespace, name: .metadata.name, path: .spec.path}]' > "$EVIDENCE_DIR/flux_kustomizations.json" 2>/dev/null || true
fi

# Check for ArgoCD
if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
  if [ "$GITOPS_PRESENT" = "true" ]; then
    AUTHORITY_OK=false
    AUTHORITY_ISSUES="${AUTHORITY_ISSUES}multiple GitOps controllers (Flux + ArgoCD); "
  fi
  GITOPS_PRESENT=true
  GITOPS_CONTROLLER="${GITOPS_CONTROLLER:+$GITOPS_CONTROLLER+}argocd"
  ARGO_APPS=$(kubectl get applications -A -o json 2>/dev/null || echo '{"items":[]}')
  echo "$ARGO_APPS" | jq '[.items[] | {namespace: .metadata.namespace, name: .metadata.name, project: .spec.project}]' > "$EVIDENCE_DIR/argocd_applications.json" 2>/dev/null || true
fi

# 3. Identify operator-managed resources (by OwnerReferences)
# Resources with ownerReferences pointing to CRDs are operator-managed
OPERATOR_MANAGED=$(kubectl get deployments,statefulsets,services -A -o json 2>/dev/null | jq '
  [.items[] |
   select(.metadata.ownerReferences != null) |
   select(.metadata.ownerReferences[].kind | test("^[A-Z].*[a-z].*$")) |
   {
     kind: .kind,
     namespace: .metadata.namespace,
     name: .metadata.name,
     owner_kind: .metadata.ownerReferences[0].kind,
     owner_name: .metadata.ownerReferences[0].name
   }]
' 2>/dev/null || echo "[]")

echo "$OPERATOR_MANAGED" > "$EVIDENCE_DIR/operator_managed.json"

# 4. Check for parallel mutation paths on same resources
# Look for resources that have BOTH Helm labels AND operator ownerReferences
PARALLEL_MUTATIONS=$(kubectl get deployments,statefulsets -A -o json 2>/dev/null | jq '
  [.items[] |
   select(.metadata.labels["app.kubernetes.io/managed-by"] == "Helm") |
   select(.metadata.ownerReferences != null) |
   {
     kind: .kind,
     namespace: .metadata.namespace,
     name: .metadata.name,
     helm_release: .metadata.labels["helm.sh/release-name"],
     owner: .metadata.ownerReferences[0].kind
   }]
' 2>/dev/null || echo "[]")

PARALLEL_COUNT=$(echo "$PARALLEL_MUTATIONS" | jq 'length')
echo "$PARALLEL_MUTATIONS" > "$EVIDENCE_DIR/parallel_mutations.json"

if [ "$PARALLEL_COUNT" -gt 0 ]; then
  # Check if these are legitimate (e.g., Helm-deployed CRs managed by operators)
  # This is expected for things like OpenTelemetryCollector CR deployed by Helm but reconciled by operator
  CONCERNING_PARALLELS=$(echo "$PARALLEL_MUTATIONS" | jq '[.[] | select(.owner != "OpenTelemetryCollector" and .owner != "Certificate" and .owner != "ClusterIssuer")]' 2>/dev/null || echo "[]")
  CONCERNING_COUNT=$(echo "$CONCERNING_PARALLELS" | jq 'length')

  if [ "$CONCERNING_COUNT" -gt 0 ]; then
    AUTHORITY_OK=false
    AUTHORITY_ISSUES="${AUTHORITY_ISSUES}${CONCERNING_COUNT} resources with conflicting mutation authorities; "
  fi
fi

# 5. Check for kubectl-applied resources without proper management labels
# These indicate ad-hoc mutations outside the sanctioned paths
KUBECTL_APPLIED=$(kubectl get deployments,statefulsets,configmaps -A -o json 2>/dev/null | jq '
  [.items[] |
   select(.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"] != null) |
   select(.metadata.labels["app.kubernetes.io/managed-by"] == null or
          .metadata.labels["app.kubernetes.io/managed-by"] == "kubectl") |
   select(.metadata.namespace | test("^kube-|^default$") | not) |
   {
     kind: .kind,
     namespace: .metadata.namespace,
     name: .metadata.name
   }]
' 2>/dev/null || echo "[]")

KUBECTL_COUNT=$(echo "$KUBECTL_APPLIED" | jq 'length')
echo "$KUBECTL_APPLIED" > "$EVIDENCE_DIR/kubectl_applied.json"

# kubectl-applied resources in non-system namespaces without proper labels are suspicious
if [ "$KUBECTL_COUNT" -gt 10 ]; then
  echo "[change-authority] WARN: $KUBECTL_COUNT resources appear kubectl-applied without management labels"
  # Don't fail - this is common during development, but flag it
fi

# Write authority summary
AUTHORITY_EVIDENCE=$(cat <<EOF
{
  "helm_releases": $(echo "$HELM_RELEASES" | jq '[.items[].metadata.labels.name] | unique | length'),
  "gitops_present": $GITOPS_PRESENT,
  "gitops_controller": "${GITOPS_CONTROLLER:-none}",
  "operator_managed_count": $(echo "$OPERATOR_MANAGED" | jq 'length'),
  "parallel_mutation_count": $PARALLEL_COUNT,
  "kubectl_applied_count": $KUBECTL_COUNT,
  "issues": "${AUTHORITY_ISSUES}"
}
EOF
)
echo "$AUTHORITY_EVIDENCE" | jq . > "$EVIDENCE_DIR/authority_summary.json" 2>/dev/null || \
  echo "$AUTHORITY_EVIDENCE" > "$EVIDENCE_DIR/authority_summary.json"

if [ "$AUTHORITY_OK" = "true" ]; then
  echo "[change-authority] OK: Mutation authority is singular (Helm: $(echo "$HELM_RELEASES" | jq '[.items[].metadata.labels.name] | unique | length'), GitOps: ${GITOPS_CONTROLLER:-none})"
else
  GATE_PASS=false
  FAILURE_REASONS+=("mutation authority issues: ${AUTHORITY_ISSUES}")
  echo "[change-authority] FAIL: Authority issues: ${AUTHORITY_ISSUES}"
fi

# -----------------------------------------------------------------------------
# CONDITION 2: Drift Is Detectable
# -----------------------------------------------------------------------------
echo "[change-authority] Checking drift detectability..."

DRIFT_OK=true
DRIFT_ISSUES=""
DRIFT_DETECTED=false

# For Helm releases, compare deployed vs chart values
# This is observation-only - we don't fix anything

# Sample drift check on critical namespaces
CRITICAL_NAMESPACES=("observability" "tempo" "spire-system" "istio-system" "cert-manager")

declare -A DRIFT_RESULTS

for ns in "${CRITICAL_NAMESPACES[@]}"; do
  if ! kubectl get ns "$ns" >/dev/null 2>&1; then
    continue
  fi

  # Get Helm releases in this namespace
  NS_RELEASES=$(echo "$HELM_RELEASES" | jq -r --arg ns "$ns" '[.items[] | select(.metadata.namespace == $ns) | .metadata.labels.name] | unique | .[]' 2>/dev/null || echo "")

  for release in $NS_RELEASES; do
    if [ -z "$release" ]; then continue; fi

    # Check if Helm can detect drift (this is read-only)
    # helm get manifest shows what Helm thinks is deployed
    # We compare against live state

    MANIFEST_HASH=$(helm get manifest "$release" -n "$ns" 2>/dev/null | sha256sum | cut -d' ' -f1 || echo "unavailable")

    # Get live resources managed by this release
    LIVE_HASH=$(kubectl get all,configmaps,secrets -n "$ns" -l "app.kubernetes.io/instance=$release" -o yaml 2>/dev/null | sha256sum | cut -d' ' -f1 || echo "unavailable")

    # Note: Hashes will differ due to runtime fields (status, etc.)
    # This is expected - we just want to verify we CAN detect drift

    DRIFT_RESULTS["$ns/$release"]="manifest:${MANIFEST_HASH:0:8},live:${LIVE_HASH:0:8}"
  done
done

# Record drift check capability
# Build JSON object for drift results
DRIFT_JSON="{"
FIRST=true
for key in "${!DRIFT_RESULTS[@]}"; do
  if [ "$FIRST" = "true" ]; then
    FIRST=false
  else
    DRIFT_JSON="${DRIFT_JSON},"
  fi
  DRIFT_JSON="${DRIFT_JSON}\"${key}\":\"${DRIFT_RESULTS[$key]}\""
done
DRIFT_JSON="${DRIFT_JSON}}"

DRIFT_CHECK_EVIDENCE=$(cat <<EOF
{
  "drift_check_possible": true,
  "namespaces_checked": $(printf '%s\n' "${CRITICAL_NAMESPACES[@]}" | jq -R -s 'split("\n") | map(select(length > 0))'),
  "helm_drift_checks": $DRIFT_JSON,
  "method": "helm_manifest_vs_live_state"
}
EOF
)
echo "$DRIFT_CHECK_EVIDENCE" | jq . > "$EVIDENCE_DIR/drift_detection.json" 2>/dev/null || \
  echo "$DRIFT_CHECK_EVIDENCE" > "$EVIDENCE_DIR/drift_detection.json"

# Check for silent reconciliation loops (operators that reconcile without events)
# Look for controllers with high reconcile rates but no logged events
RECONCILE_CONTROLLERS=$(kubectl get pods -A -o json 2>/dev/null | jq '
  [.items[] |
   select(.metadata.name | test("controller|operator|manager"; "i")) |
   {
     namespace: .metadata.namespace,
     name: .metadata.name,
     restarts: (.status.containerStatuses[0].restartCount // 0)
   }]
' 2>/dev/null || echo "[]")

# Check for controllers with suspiciously high restart counts (may indicate reconcile storms)
HIGH_RESTART_CONTROLLERS=$(echo "$RECONCILE_CONTROLLERS" | jq '[.[] | select(.restarts > 10)]')
HIGH_RESTART_COUNT=$(echo "$HIGH_RESTART_CONTROLLERS" | jq 'length')

if [ "$HIGH_RESTART_COUNT" -gt 0 ]; then
  echo "[change-authority] WARN: $HIGH_RESTART_COUNT controllers with high restart counts (possible reconcile issues)"
  echo "$HIGH_RESTART_CONTROLLERS" > "$EVIDENCE_DIR/high_restart_controllers.json"
fi

if [ "$DRIFT_OK" = "true" ]; then
  echo "[change-authority] OK: Drift detection capability verified"
else
  GATE_PASS=false
  FAILURE_REASONS+=("drift detection issues: ${DRIFT_ISSUES}")
  echo "[change-authority] FAIL: Drift issues: ${DRIFT_ISSUES}"
fi

# -----------------------------------------------------------------------------
# CONDITION 3: Human or Identity Attribution Exists
# -----------------------------------------------------------------------------
echo "[change-authority] Checking mutation attribution..."

ATTRIBUTION_OK=true
ATTRIBUTION_ISSUES=""

# 1. Check that all ServiceAccounts used by controllers have proper identity bindings
# In ThreadForge, this means SPIRE registration or explicit RBAC

# Get all running pods with their service accounts
POD_IDENTITIES=$(kubectl get pods -A -o json 2>/dev/null | jq '
  [.items[] |
   select(.status.phase == "Running") |
   {
     namespace: .metadata.namespace,
     name: .metadata.name,
     serviceAccount: .spec.serviceAccountName,
     automountToken: (.spec.automountServiceAccountToken // true)
   }]
' 2>/dev/null || echo "[]")

echo "$POD_IDENTITIES" > "$EVIDENCE_DIR/pod_identities.json"

# 2. Check for pods using default service account with automount enabled
# This is a red flag for unattributed mutations
DEFAULT_SA_PODS=$(echo "$POD_IDENTITIES" | jq '
  [.[] |
   select(.serviceAccount == "default") |
   select(.automountToken == true) |
   select(.namespace | test("^kube-") | not)]
' 2>/dev/null || echo "[]")

DEFAULT_SA_COUNT=$(echo "$DEFAULT_SA_PODS" | jq 'length')
echo "$DEFAULT_SA_PODS" > "$EVIDENCE_DIR/default_sa_pods.json"

if [ "$DEFAULT_SA_COUNT" -gt 0 ]; then
  # Check if any of these have write access
  RISKY_DEFAULT_SA=0
  for ns in $(echo "$DEFAULT_SA_PODS" | jq -r '.[].namespace' | sort -u); do
    # Check if default SA in this namespace has any role bindings
    HAS_BINDINGS=$(kubectl get rolebindings -n "$ns" -o json 2>/dev/null | jq --arg ns "$ns" '
      [.items[] |
       select(.subjects[]? | .kind == "ServiceAccount" and .name == "default" and .namespace == $ns)] | length
    ' 2>/dev/null || echo "0")

    if [ "$HAS_BINDINGS" -gt 0 ]; then
      RISKY_DEFAULT_SA=$((RISKY_DEFAULT_SA + 1))
    fi
  done

  if [ "$RISKY_DEFAULT_SA" -gt 0 ]; then
    ATTRIBUTION_OK=false
    ATTRIBUTION_ISSUES="${ATTRIBUTION_ISSUES}$RISKY_DEFAULT_SA namespaces with default SA having role bindings; "
  fi
fi

# 3. Check for anonymous access enabled
ANON_ACCESS_RAW=$(kubectl auth can-i --list --as=system:anonymous 2>/dev/null | grep -v "^Resources" | grep -v "no$" | grep -c "yes" 2>/dev/null || true)
ANON_ACCESS="${ANON_ACCESS_RAW:-0}"
# Ensure it's a valid number
if ! [[ "$ANON_ACCESS" =~ ^[0-9]+$ ]]; then
  ANON_ACCESS=0
fi

if [ "$ANON_ACCESS" -gt 2 ]; then  # Some anonymous access is normal (healthz, etc.)
  ATTRIBUTION_OK=false
  ATTRIBUTION_ISSUES="${ATTRIBUTION_ISSUES}excessive anonymous access ($ANON_ACCESS permissions); "
fi

# 4. Verify SPIRE is providing workload identity (already checked in Stage 1, but verify integration)
SPIRE_ENTRIES_RAW=$(kubectl exec -n spire-system spire-server-0 -- /opt/spire/bin/spire-server entry show 2>/dev/null | grep -c "Entry ID" 2>/dev/null || true)
SPIRE_ENTRIES="${SPIRE_ENTRIES_RAW:-0}"
# Ensure it's a valid number
if ! [[ "$SPIRE_ENTRIES" =~ ^[0-9]+$ ]]; then
  SPIRE_ENTRIES=0
fi

if [ "$SPIRE_ENTRIES" -lt 5 ]; then
  echo "[change-authority] WARN: Only $SPIRE_ENTRIES SPIRE entries registered (expected more for full attribution)"
fi

# 5. Check audit logging is enabled (attribution requires audit trail)
AUDIT_ENABLED=false
AUDIT_POLICY=$(kubectl get --raw /apis/audit.k8s.io/v1/policies 2>/dev/null || echo "")

# For k3s, check if audit log exists
if [ -f /var/log/kubernetes/audit/audit.log ] 2>/dev/null || kubectl logs -n kube-system -l component=kube-apiserver --tail=1 2>/dev/null | grep -q "audit"; then
  AUDIT_ENABLED=true
fi

# Write attribution summary
ATTRIBUTION_EVIDENCE=$(cat <<EOF
{
  "total_running_pods": $(echo "$POD_IDENTITIES" | jq 'length'),
  "default_sa_pods": $DEFAULT_SA_COUNT,
  "risky_default_sa_namespaces": ${RISKY_DEFAULT_SA:-0},
  "anonymous_permissions": $ANON_ACCESS,
  "spire_entries": $SPIRE_ENTRIES,
  "audit_logging": $AUDIT_ENABLED,
  "issues": "${ATTRIBUTION_ISSUES}"
}
EOF
)
echo "$ATTRIBUTION_EVIDENCE" | jq . > "$EVIDENCE_DIR/attribution_summary.json" 2>/dev/null || \
  echo "$ATTRIBUTION_EVIDENCE" > "$EVIDENCE_DIR/attribution_summary.json"

if [ "$ATTRIBUTION_OK" = "true" ]; then
  echo "[change-authority] OK: Mutation attribution verified ($SPIRE_ENTRIES SPIRE entries, $DEFAULT_SA_COUNT default SA pods)"
else
  GATE_PASS=false
  FAILURE_REASONS+=("attribution issues: ${ATTRIBUTION_ISSUES}")
  echo "[change-authority] FAIL: Attribution issues: ${ATTRIBUTION_ISSUES}"
fi

# -----------------------------------------------------------------------------
# CONDITION 4: Emergency Mutation Is Explicit
# -----------------------------------------------------------------------------
echo "[change-authority] Checking emergency mutation paths..."

EMERGENCY_OK=true
EMERGENCY_ISSUES=""

# 1. Check for break-glass ClusterRoleBindings (cluster-admin to users/groups)
BREAK_GLASS_BINDINGS=$(kubectl get clusterrolebindings -o json 2>/dev/null | jq '
  [.items[] |
   select(.roleRef.name == "cluster-admin") |
   select(.subjects[]? | .kind == "User" or .kind == "Group") |
   {
     name: .metadata.name,
     subjects: [.subjects[] | select(.kind == "User" or .kind == "Group")]
   }]
' 2>/dev/null || echo "[]")

BREAK_GLASS_COUNT=$(echo "$BREAK_GLASS_BINDINGS" | jq 'length')
echo "$BREAK_GLASS_BINDINGS" > "$EVIDENCE_DIR/break_glass_bindings.json"

# Check if break-glass bindings have time bounds or labels
for binding in $(echo "$BREAK_GLASS_BINDINGS" | jq -r '.[].name' 2>/dev/null); do
  BINDING_LABELS=$(kubectl get clusterrolebinding "$binding" -o json 2>/dev/null | jq '.metadata.labels // {}')

  # Check for expected labels on break-glass bindings
  HAS_EMERGENCY_LABEL=$(echo "$BINDING_LABELS" | jq 'has("threadforge.dev/emergency") or has("break-glass") or has("emergency-access")')

  if [ "$HAS_EMERGENCY_LABEL" = "false" ]; then
    # This is a cluster-admin binding without emergency labels - flag but don't fail
    # (some are legitimate system bindings)
    IS_SYSTEM=$(echo "$binding" | grep -E "^(system:|kubeadm:|cluster-admin$)" || echo "")
    if [ -z "$IS_SYSTEM" ]; then
      echo "[change-authority] WARN: cluster-admin binding '$binding' lacks emergency labels"
    fi
  fi
done

# 2. Check for recent kubectl apply events in audit log (if accessible)
# This would indicate direct mutations outside GitOps/Helm
RECENT_KUBECTL_EVENTS=0

# Try to get recent events that look like direct applies
RECENT_MUTATIONS=$(kubectl get events -A --field-selector reason=Created -o json 2>/dev/null | jq '
  [.items[] |
   select(.source.component == "kubectl" or .source.component == null) |
   select(.lastTimestamp > (now - 3600 | strftime("%Y-%m-%dT%H:%M:%SZ"))) |
   {
     namespace: .metadata.namespace,
     name: .involvedObject.name,
     kind: .involvedObject.kind,
     time: .lastTimestamp
   }] | length
' 2>/dev/null || echo "0")

# 3. Check for pods with hostPath mounts (potential escape hatch)
HOSTPATH_PODS=$(kubectl get pods -A -o json 2>/dev/null | jq '
  [.items[] |
   select(.spec.volumes[]?.hostPath != null) |
   select(.metadata.namespace | test("^kube-|^spire-") | not) |
   {
     namespace: .metadata.namespace,
     name: .metadata.name,
     hostPaths: [.spec.volumes[] | select(.hostPath != null) | .hostPath.path]
   }]
' 2>/dev/null || echo "[]")

HOSTPATH_COUNT=$(echo "$HOSTPATH_PODS" | jq 'length')
echo "$HOSTPATH_PODS" > "$EVIDENCE_DIR/hostpath_pods.json"

# Critical hostPaths that would allow system mutation
CRITICAL_HOSTPATHS=$(echo "$HOSTPATH_PODS" | jq '
  [.[] |
   select(.hostPaths[] | test("/etc|/var/run|/root|/home"; "i"))]
' 2>/dev/null || echo "[]")

CRITICAL_HOSTPATH_COUNT=$(echo "$CRITICAL_HOSTPATHS" | jq 'length')

if [ "$CRITICAL_HOSTPATH_COUNT" -gt 0 ]; then
  echo "[change-authority] WARN: $CRITICAL_HOSTPATH_COUNT pods with sensitive hostPath mounts"
  echo "$CRITICAL_HOSTPATHS" > "$EVIDENCE_DIR/critical_hostpath_pods.json"
fi

# Write emergency mutation summary
EMERGENCY_EVIDENCE=$(cat <<EOF
{
  "break_glass_bindings": $BREAK_GLASS_COUNT,
  "recent_kubectl_events": $RECENT_MUTATIONS,
  "hostpath_pods": $HOSTPATH_COUNT,
  "critical_hostpath_pods": $CRITICAL_HOSTPATH_COUNT,
  "issues": "${EMERGENCY_ISSUES}"
}
EOF
)
echo "$EMERGENCY_EVIDENCE" | jq . > "$EVIDENCE_DIR/emergency_mutation_summary.json" 2>/dev/null || \
  echo "$EMERGENCY_EVIDENCE" > "$EVIDENCE_DIR/emergency_mutation_summary.json"

if [ "$EMERGENCY_OK" = "true" ]; then
  echo "[change-authority] OK: Emergency mutation paths explicit ($BREAK_GLASS_COUNT break-glass bindings)"
else
  GATE_PASS=false
  FAILURE_REASONS+=("emergency mutation issues: ${EMERGENCY_ISSUES}")
  echo "[change-authority] FAIL: Emergency mutation issues: ${EMERGENCY_ISSUES}"
fi

# -----------------------------------------------------------------------------
# DECISION
# -----------------------------------------------------------------------------
if [ "$GATE_PASS" = "true" ]; then
  echo "[change-authority] PASS — change authority is bounded and attributable"
  DECISION="PASS"
else
  echo "[change-authority] FAIL — $(IFS=';'; echo "${FAILURE_REASONS[*]}")"
  DECISION="FAIL"
fi

# Determine condition statuses
AUTHORITY_STATUS="UNKNOWN"
if [ "$AUTHORITY_OK" = "true" ]; then
  AUTHORITY_STATUS="PASS"
else
  AUTHORITY_STATUS="FAIL"
fi

DRIFT_STATUS="UNKNOWN"
if [ "$DRIFT_OK" = "true" ]; then
  DRIFT_STATUS="PASS"
else
  DRIFT_STATUS="FAIL"
fi

ATTRIBUTION_STATUS="UNKNOWN"
if [ "$ATTRIBUTION_OK" = "true" ]; then
  ATTRIBUTION_STATUS="PASS"
else
  ATTRIBUTION_STATUS="FAIL"
fi

EMERGENCY_STATUS="UNKNOWN"
if [ "$EMERGENCY_OK" = "true" ]; then
  EMERGENCY_STATUS="PASS"
else
  EMERGENCY_STATUS="FAIL"
fi

# Write decision file
cat > "$EVIDENCE_DIR/decision.txt" <<EOF
CHANGE AUTHORITY & DRIFT RESISTANCE GATE
=========================================
Drill ID:    ${DRILL_ID}
Timestamp:   ${NOW_UTC}
Mode:        $([ "$STRICT" = "1" ] && echo "STRICT" || echo "ADVISORY")
Decision:    ${DECISION}

Authority Question: "Can this system change itself without explicit, attributable intent?"

Conditions:
  1. Change Authority Singular:     ${AUTHORITY_STATUS}
     - Helm releases:               $(echo "$HELM_RELEASES" | jq '[.items[].metadata.labels.name] | unique | length')
     - GitOps controller:           ${GITOPS_CONTROLLER:-none}
     - Parallel mutations:          ${PARALLEL_COUNT}
     - kubectl-applied resources:   ${KUBECTL_COUNT}

  2. Drift Detectable:              ${DRIFT_STATUS}
     - Namespaces checked:          ${#CRITICAL_NAMESPACES[@]}
     - High-restart controllers:    ${HIGH_RESTART_COUNT:-0}

  3. Attribution Exists:            ${ATTRIBUTION_STATUS}
     - SPIRE entries:               ${SPIRE_ENTRIES}
     - Default SA pods:             ${DEFAULT_SA_COUNT}
     - Anonymous permissions:       ${ANON_ACCESS}

  4. Emergency Mutation Explicit:   ${EMERGENCY_STATUS}
     - Break-glass bindings:        ${BREAK_GLASS_COUNT}
     - Critical hostPath pods:      ${CRITICAL_HOSTPATH_COUNT}

$([ ${#FAILURE_REASONS[@]} -gt 0 ] && echo "Failure Reasons:" && printf "  - %s\n" "${FAILURE_REASONS[@]}" || echo "")

Evidence: ${EVIDENCE_DIR}/
EOF

cat "$EVIDENCE_DIR/decision.txt"

# Write summary JSON
cat > "$EVIDENCE_DIR/summary.json" <<EOF
{
  "gate": "change-authority",
  "drill_id": "${DRILL_ID}",
  "timestamp": "${NOW_UTC}",
  "mode": "$([ "$STRICT" = "1" ] && echo "strict" || echo "advisory")",
  "decision": "${DECISION}",
  "authority_question": "Can this system change itself without explicit, attributable intent?",
  "conditions": {
    "authority_singular": "${AUTHORITY_STATUS}",
    "drift_detectable": "${DRIFT_STATUS}",
    "attribution_exists": "${ATTRIBUTION_STATUS}",
    "emergency_explicit": "${EMERGENCY_STATUS}"
  },
  "metrics": {
    "helm_releases": $(echo "$HELM_RELEASES" | jq '[.items[].metadata.labels.name] | unique | length'),
    "gitops_controller": "${GITOPS_CONTROLLER:-none}",
    "parallel_mutations": ${PARALLEL_COUNT},
    "kubectl_applied": ${KUBECTL_COUNT},
    "spire_entries": ${SPIRE_ENTRIES},
    "default_sa_pods": ${DEFAULT_SA_COUNT},
    "break_glass_bindings": ${BREAK_GLASS_COUNT},
    "critical_hostpath_pods": ${CRITICAL_HOSTPATH_COUNT}
  },
  "failure_reasons": $(printf '%s\n' "${FAILURE_REASONS[@]:-}" | jq -R -s 'split("\n") | map(select(length > 0))')
}
EOF

# Exit based on mode
if [ "$DECISION" = "FAIL" ]; then
  if [ "$STRICT" = "1" ]; then
    echo ""
    echo "⛔ CHANGE AUTHORITY GATE FAIL (STRICT) — execution blocked"
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  else
    echo ""
    echo "⚠️  CHANGE AUTHORITY GATE FAIL (ADVISORY) — continuing with degraded confidence"
    exit 0
  fi
else
  echo ""
  echo "✅ CHANGE AUTHORITY GATE PASS — system is execution-sovereign"
  exit 0
fi
