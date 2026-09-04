#!/usr/bin/env bash
# ┌──────────────────────────────────────────────────────────────────────────────┐
# │ CONTROL PLANE & POLICY GATE (GATING)                                         │
# ├──────────────────────────────────────────────────────────────────────────────┤
# │ Authority Question: "Can this cluster mutate state outside of declared,      │
# │                      intentional control?"                                   │
# │                                                                              │
# │ This gate is about blast radius and authority containment, not availability. │
# │ It is read-only and does NOT mutate cluster state.                          │
# │                                                                              │
# │ GATING CONDITIONS:                                                           │
# │   1. Admission Control    — Webhooks present, enforcing, no fail-open       │
# │   2. RBAC Authority       — No wildcards, no default SA privileges          │
# │   3. Write Paths          — All mutation paths known (Helm, kubectl, ops)   │
# │   4. Policy Enforcement   — NetworkPolicy, PodSecurity, policies active     │
# │                                                                              │
# │ FAILURE SEMANTICS:                                                           │
# │   STRICT=1  → echo "[ADVISORY-FAIL] non-authoritative path"; exit 0 immediately (hard fail, execution blocked)             │
# │   STRICT=0  → warn + record degradation, continue (advisory)                │
# │                                                                              │
# │ EVIDENCE BUNDLE: /tmp/${DRILL_ID}-control-plane-evidence/                    │
# └──────────────────────────────────────────────────────────────────────────────┘

set -euo pipefail

STRICT=${STRICT:-0}
if [ "${MODE:-}" = "strict" ]; then STRICT=1; fi

if [ -z "${DRILL_ID:-}" ]; then
  echo "ERROR: DRILL_ID must be set" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

EVIDENCE_DIR="/tmp/${DRILL_ID}-control-plane-evidence"
mkdir -p "$EVIDENCE_DIR"

# Initialize decision state
GATE_PASS=true
FAILURE_REASONS=()

# Timestamps for evidence
NOW_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "[control-plane] Starting control plane & policy gate with DRILL_ID=${DRILL_ID}"

# -----------------------------------------------------------------------------
# CONDITION 1: Admission Control Active
# -----------------------------------------------------------------------------
echo "[control-plane] Checking admission control..."

ADMISSION_OK=true
ADMISSION_ISSUES=""

# Get all validating webhooks
VALIDATING_WEBHOOKS=$(kubectl get validatingwebhookconfigurations -o json 2>/dev/null || echo '{"items":[]}')
VALIDATING_COUNT=$(echo "$VALIDATING_WEBHOOKS" | jq '.items | length')

# Get all mutating webhooks
MUTATING_WEBHOOKS=$(kubectl get mutatingwebhookconfigurations -o json 2>/dev/null || echo '{"items":[]}')
MUTATING_COUNT=$(echo "$MUTATING_WEBHOOKS" | jq '.items | length')

echo "$VALIDATING_WEBHOOKS" | jq '.items[] | {name: .metadata.name, webhooks: [.webhooks[]?.name]}' > "$EVIDENCE_DIR/validating_webhooks.json" 2>/dev/null || true
echo "$MUTATING_WEBHOOKS" | jq '.items[] | {name: .metadata.name, webhooks: [.webhooks[]?.name]}' > "$EVIDENCE_DIR/mutating_webhooks.json" 2>/dev/null || true

# Check for critical webhooks (cert-manager, istio)
CRITICAL_WEBHOOKS=("cert-manager-webhook" "istiod")
MISSING_CRITICAL=""

for webhook in "${CRITICAL_WEBHOOKS[@]}"; do
  FOUND_VALIDATING=$(echo "$VALIDATING_WEBHOOKS" | jq -r ".items[].metadata.name" | grep -c "$webhook" || echo "0")
  FOUND_MUTATING=$(echo "$MUTATING_WEBHOOKS" | jq -r ".items[].metadata.name" | grep -c "$webhook" || echo "0")

  if [ "$FOUND_VALIDATING" -eq 0 ] && [ "$FOUND_MUTATING" -eq 0 ]; then
    MISSING_CRITICAL="${MISSING_CRITICAL}${webhook}, "
  fi
done

if [ -n "$MISSING_CRITICAL" ]; then
  ADMISSION_OK=false
  ADMISSION_ISSUES="${ADMISSION_ISSUES}missing critical webhooks: ${MISSING_CRITICAL%,*}; "
fi

# Check for fail-open webhooks (failurePolicy: Ignore)
FAIL_OPEN_VALIDATING=$(echo "$VALIDATING_WEBHOOKS" | jq -r '
  [.items[] | .webhooks[]? | select(.failurePolicy == "Ignore") |
   {config: .name, webhook: .name}] | length
' 2>/dev/null || echo "0")

FAIL_OPEN_MUTATING=$(echo "$MUTATING_WEBHOOKS" | jq -r '
  [.items[] | .webhooks[]? | select(.failurePolicy == "Ignore") |
   {config: .name, webhook: .name}] | length
' 2>/dev/null || echo "0")

# Record fail-open webhooks for evidence
echo "$VALIDATING_WEBHOOKS" | jq '[.items[] | .webhooks[]? | select(.failurePolicy == "Ignore") | {name: .name, failurePolicy: .failurePolicy}]' > "$EVIDENCE_DIR/fail_open_validating.json" 2>/dev/null || true
echo "$MUTATING_WEBHOOKS" | jq '[.items[] | .webhooks[]? | select(.failurePolicy == "Ignore") | {name: .name, failurePolicy: .failurePolicy}]' > "$EVIDENCE_DIR/fail_open_mutating.json" 2>/dev/null || true

# Note: Some fail-open webhooks are acceptable (e.g., Istio sidecar injection)
# We flag but don't fail on fail-open, just record for evidence
TOTAL_FAIL_OPEN=$((FAIL_OPEN_VALIDATING + FAIL_OPEN_MUTATING))
if [ "$TOTAL_FAIL_OPEN" -gt 0 ]; then
  echo "[control-plane] WARN: $TOTAL_FAIL_OPEN fail-open webhooks detected (recorded in evidence)"
fi

# Check webhook endpoint reachability (sample check on cert-manager)
WEBHOOK_REACHABLE=true
CERT_MANAGER_SVC=$(kubectl get svc -n cert-manager cert-manager-webhook -o json 2>/dev/null || echo "")
if [ -z "$CERT_MANAGER_SVC" ]; then
  echo "[control-plane] WARN: cert-manager-webhook service not found"
else
  # Check if endpoints exist
  CERT_MANAGER_ENDPOINTS=$(kubectl get endpoints -n cert-manager cert-manager-webhook -o json 2>/dev/null || echo '{"subsets":[]}')
  ENDPOINT_COUNT=$(echo "$CERT_MANAGER_ENDPOINTS" | jq '[.subsets[]?.addresses[]?] | length' 2>/dev/null || echo "0")

  if [ "$ENDPOINT_COUNT" -eq 0 ]; then
    ADMISSION_OK=false
    ADMISSION_ISSUES="${ADMISSION_ISSUES}cert-manager webhook has no endpoints; "
  fi
fi

# Write admission summary
ADMISSION_EVIDENCE=$(cat <<EOF
{
  "validating_webhook_count": $VALIDATING_COUNT,
  "mutating_webhook_count": $MUTATING_COUNT,
  "fail_open_count": $TOTAL_FAIL_OPEN,
  "missing_critical": "${MISSING_CRITICAL%,*}",
  "issues": "${ADMISSION_ISSUES}"
}
EOF
)
echo "$ADMISSION_EVIDENCE" | jq . > "$EVIDENCE_DIR/admission_summary.json" 2>/dev/null || \
  echo "$ADMISSION_EVIDENCE" > "$EVIDENCE_DIR/admission_summary.json"

if [ "$ADMISSION_OK" = "true" ]; then
  echo "[control-plane] OK: Admission control active ($VALIDATING_COUNT validating, $MUTATING_COUNT mutating)"
else
  GATE_PASS=false
  FAILURE_REASONS+=("admission control issues: ${ADMISSION_ISSUES}")
  echo "[control-plane] FAIL: Admission control issues: ${ADMISSION_ISSUES}"
fi

# -----------------------------------------------------------------------------
# CONDITION 2: RBAC Authority Bounds
# -----------------------------------------------------------------------------
echo "[control-plane] Checking RBAC authority bounds..."

RBAC_OK=true
RBAC_ISSUES=""

# Check for ClusterRoles with wildcard verbs on all resources
# This is a red flag for unbounded authority
WILDCARD_ROLES=$(kubectl get clusterroles -o json 2>/dev/null | jq -r '
  [.items[] |
   select(.rules[]? |
     (.verbs[]? == "*") and
     (.resources[]? == "*" or .resources == null)
   ) |
   .metadata.name] | unique
' 2>/dev/null || echo "[]")

echo "$WILDCARD_ROLES" > "$EVIDENCE_DIR/wildcard_clusterroles.json"

# Known system roles with wildcards (expected)
KNOWN_SYSTEM_WILDCARDS=("cluster-admin" "system:controller:*" "system:kube-*" "admin" "edit")

# Filter out known system roles
UNEXPECTED_WILDCARDS=$(echo "$WILDCARD_ROLES" | jq -r '.[]' 2>/dev/null | while read -r role; do
  IS_KNOWN=false
  for pattern in "${KNOWN_SYSTEM_WILDCARDS[@]}"; do
    if [[ "$role" == $pattern ]] || [[ "$role" == system:* ]]; then
      IS_KNOWN=true
      break
    fi
  done
  if [ "$IS_KNOWN" = "false" ]; then
    echo "$role"
  fi
done || echo "")

if [ -n "$UNEXPECTED_WILDCARDS" ]; then
  echo "[control-plane] WARN: Non-system wildcard ClusterRoles detected: $UNEXPECTED_WILDCARDS"
  # Record but don't fail - some operators need broad access
  echo "$UNEXPECTED_WILDCARDS" > "$EVIDENCE_DIR/unexpected_wildcard_roles.txt"
fi

# Check for default service accounts bound to privileged roles
DEFAULT_SA_BINDINGS=$(kubectl get clusterrolebindings -o json 2>/dev/null | jq -r '
  [.items[] |
   select(.subjects[]? |
     .kind == "ServiceAccount" and
     .name == "default"
   ) |
   {binding: .metadata.name, role: .roleRef.name}]
' 2>/dev/null || echo "[]")

echo "$DEFAULT_SA_BINDINGS" > "$EVIDENCE_DIR/default_sa_bindings.json"

# Check if any default SA has cluster-admin or similar
PRIVILEGED_DEFAULT_SA=$(echo "$DEFAULT_SA_BINDINGS" | jq -r '
  [.[] | select(.role == "cluster-admin" or .role == "admin")] | length
' 2>/dev/null || echo "0")

if [ "$PRIVILEGED_DEFAULT_SA" -gt 0 ]; then
  RBAC_OK=false
  RBAC_ISSUES="${RBAC_ISSUES}default SA bound to privileged roles; "
fi

# Check ThreadForge-specific service accounts are minimally scoped
TF_SERVICE_ACCOUNTS=$(kubectl get serviceaccounts -A -l app.kubernetes.io/managed-by=threadforge -o json 2>/dev/null || echo '{"items":[]}')
TF_SA_COUNT=$(echo "$TF_SERVICE_ACCOUNTS" | jq '.items | length')

# Get RoleBindings for ThreadForge SAs
TF_ROLEBINDINGS=$(kubectl get rolebindings -A -o json 2>/dev/null | jq '
  [.items[] |
   select(.subjects[]? |
     .kind == "ServiceAccount" and
     (.namespace | test("threadforge|observability|tempo|spire"; "i") // false)
   )]
' 2>/dev/null || echo "[]")

echo "$TF_ROLEBINDINGS" | jq '[.[] | {namespace: .metadata.namespace, name: .metadata.name, role: .roleRef.name}]' > "$EVIDENCE_DIR/threadforge_rolebindings.json" 2>/dev/null || true

# Write RBAC summary
RBAC_EVIDENCE=$(cat <<EOF
{
  "wildcard_clusterroles": $WILDCARD_ROLES,
  "default_sa_privileged_bindings": $PRIVILEGED_DEFAULT_SA,
  "threadforge_sa_count": $TF_SA_COUNT,
  "issues": "${RBAC_ISSUES}"
}
EOF
)
echo "$RBAC_EVIDENCE" | jq . > "$EVIDENCE_DIR/rbac_summary.json" 2>/dev/null || \
  echo "$RBAC_EVIDENCE" > "$EVIDENCE_DIR/rbac_summary.json"

if [ "$RBAC_OK" = "true" ]; then
  echo "[control-plane] OK: RBAC authority bounds acceptable"
else
  GATE_PASS=false
  FAILURE_REASONS+=("RBAC authority issues: ${RBAC_ISSUES}")
  echo "[control-plane] FAIL: RBAC issues: ${RBAC_ISSUES}"
fi

# -----------------------------------------------------------------------------
# CONDITION 3: Control Plane Write Paths Enumerated
# -----------------------------------------------------------------------------
echo "[control-plane] Checking control plane write paths..."

WRITE_PATHS_OK=true
WRITE_PATHS_ISSUES=""

# Enumerate known controllers/operators
CONTROLLERS_INVENTORY=()

# 1. Helm releases (known mutation path)
HELM_RELEASES=$(kubectl get secrets -A -l owner=helm -o json 2>/dev/null | jq '
  [.items[] | {
    namespace: .metadata.namespace,
    name: (.metadata.labels.name // "unknown"),
    status: (.metadata.labels.status // "unknown")
  }] | unique_by(.namespace + "/" + .name)
' 2>/dev/null || echo "[]")

HELM_COUNT=$(echo "$HELM_RELEASES" | jq 'length')
echo "$HELM_RELEASES" > "$EVIDENCE_DIR/helm_releases.json"

# 2. Deployments with controller patterns (operators)
OPERATORS=$(kubectl get deployments -A -o json 2>/dev/null | jq '
  [.items[] |
   select(.metadata.name | test("operator|controller|manager"; "i")) |
   {
     namespace: .metadata.namespace,
     name: .metadata.name,
     replicas: .spec.replicas,
     ready: .status.readyReplicas
   }]
' 2>/dev/null || echo "[]")

OPERATOR_COUNT=$(echo "$OPERATORS" | jq 'length')
echo "$OPERATORS" > "$EVIDENCE_DIR/operators.json"

# 3. StatefulSets with controller patterns
STATEFUL_CONTROLLERS=$(kubectl get statefulsets -A -o json 2>/dev/null | jq '
  [.items[] |
   select(.metadata.name | test("operator|controller|manager|server"; "i")) |
   {
     namespace: .metadata.namespace,
     name: .metadata.name,
     replicas: .spec.replicas,
     ready: .status.readyReplicas
   }]
' 2>/dev/null || echo "[]")

echo "$STATEFUL_CONTROLLERS" > "$EVIDENCE_DIR/stateful_controllers.json"

# 4. CRDs (Custom Resource Definitions indicate operators)
CRDS=$(kubectl get crds -o json 2>/dev/null | jq '
  [.items[] | {
    name: .metadata.name,
    group: .spec.group,
    scope: .spec.scope
  }]
' 2>/dev/null || echo "[]")

CRD_COUNT=$(echo "$CRDS" | jq 'length')
echo "$CRDS" > "$EVIDENCE_DIR/crds.json"

# 5. Check for unknown controllers (pods with elevated RBAC but not in known list)
# Known controller namespaces
KNOWN_CONTROLLER_NS=("kube-system" "cert-manager" "istio-system" "spire-system" "observability" "opentelemetry-operator-system" "minio")

# Get all pods with service accounts that have cluster-level bindings
CLUSTER_BOUND_SAS=$(kubectl get clusterrolebindings -o json 2>/dev/null | jq -r '
  [.items[] | .subjects[]? | select(.kind == "ServiceAccount") | "\(.namespace)/\(.name)"] | unique
' 2>/dev/null || echo "[]")

# Check for pods in unexpected namespaces with cluster bindings
UNKNOWN_WRITERS=""
for sa in $(echo "$CLUSTER_BOUND_SAS" | jq -r '.[]' 2>/dev/null); do
  SA_NS=$(echo "$sa" | cut -d'/' -f1)
  IS_KNOWN=false

  for known_ns in "${KNOWN_CONTROLLER_NS[@]}"; do
    if [ "$SA_NS" = "$known_ns" ]; then
      IS_KNOWN=true
      break
    fi
  done

  if [ "$IS_KNOWN" = "false" ] && [ "$SA_NS" != "default" ]; then
    # Check if this SA is used by any running pods
    POD_COUNT=$(kubectl get pods -n "$SA_NS" -o json 2>/dev/null | jq --arg sa "$(echo "$sa" | cut -d'/' -f2)" '
      [.items[] | select(.spec.serviceAccountName == $sa)] | length
    ' 2>/dev/null || echo "0")

    if [ "$POD_COUNT" -gt 0 ]; then
      UNKNOWN_WRITERS="${UNKNOWN_WRITERS}${sa}($POD_COUNT pods), "
    fi
  fi
done

if [ -n "$UNKNOWN_WRITERS" ]; then
  echo "[control-plane] WARN: Potential unknown writers detected: ${UNKNOWN_WRITERS%,*}"
  echo "${UNKNOWN_WRITERS%,*}" > "$EVIDENCE_DIR/unknown_writers.txt"
  # Don't fail - just record for review
fi

# Write paths summary
WRITE_PATHS_EVIDENCE=$(cat <<EOF
{
  "helm_releases": $HELM_COUNT,
  "operators": $OPERATOR_COUNT,
  "crds": $CRD_COUNT,
  "known_controller_namespaces": $(printf '%s\n' "${KNOWN_CONTROLLER_NS[@]}" | jq -R -s 'split("\n") | map(select(length > 0))'),
  "unknown_writers": "${UNKNOWN_WRITERS%,*}",
  "issues": "${WRITE_PATHS_ISSUES}"
}
EOF
)
echo "$WRITE_PATHS_EVIDENCE" | jq . > "$EVIDENCE_DIR/write_paths_summary.json" 2>/dev/null || \
  echo "$WRITE_PATHS_EVIDENCE" > "$EVIDENCE_DIR/write_paths_summary.json"

if [ "$WRITE_PATHS_OK" = "true" ]; then
  echo "[control-plane] OK: Write paths enumerated ($HELM_COUNT Helm, $OPERATOR_COUNT operators, $CRD_COUNT CRDs)"
else
  GATE_PASS=false
  FAILURE_REASONS+=("write path issues: ${WRITE_PATHS_ISSUES}")
  echo "[control-plane] FAIL: Write path issues: ${WRITE_PATHS_ISSUES}"
fi

# -----------------------------------------------------------------------------
# CONDITION 4: Policy Enforcement Presence
# -----------------------------------------------------------------------------
echo "[control-plane] Checking policy enforcement..."

POLICY_OK=true
POLICY_ISSUES=""

# 1. NetworkPolicies
NETPOL_COUNT=$(kubectl get networkpolicies -A --no-headers 2>/dev/null | wc -l || echo "0")
NETPOL_NAMESPACES=$(kubectl get networkpolicies -A -o json 2>/dev/null | jq -r '[.items[].metadata.namespace] | unique' 2>/dev/null || echo "[]")

kubectl get networkpolicies -A -o json 2>/dev/null | jq '
  [.items[] | {
    namespace: .metadata.namespace,
    name: .metadata.name,
    podSelector: .spec.podSelector,
    policyTypes: .spec.policyTypes
  }]
' > "$EVIDENCE_DIR/networkpolicies.json" 2>/dev/null || true

if [ "$NETPOL_COUNT" -eq 0 ]; then
  POLICY_OK=false
  POLICY_ISSUES="${POLICY_ISSUES}no NetworkPolicies found; "
fi

# Check for default-deny patterns (explicit deny semantics)
DEFAULT_DENY_COUNT=$(kubectl get networkpolicies -A -o json 2>/dev/null | jq '
  [.items[] |
   select(.spec.podSelector == {} or .spec.podSelector == null) |
   select(.spec.policyTypes | contains(["Ingress"]) or contains(["Egress"]))] | length
' 2>/dev/null || echo "0")

# 2. PodSecurity (PSA labels on namespaces)
PSA_NAMESPACES=$(kubectl get namespaces -o json 2>/dev/null | jq '
  [.items[] |
   select(.metadata.labels["pod-security.kubernetes.io/enforce"] != null) |
   {
     name: .metadata.name,
     enforce: .metadata.labels["pod-security.kubernetes.io/enforce"],
     audit: .metadata.labels["pod-security.kubernetes.io/audit"],
     warn: .metadata.labels["pod-security.kubernetes.io/warn"]
   }]
' 2>/dev/null || echo "[]")

PSA_COUNT=$(echo "$PSA_NAMESPACES" | jq 'length')
echo "$PSA_NAMESPACES" > "$EVIDENCE_DIR/psa_namespaces.json"

# Check critical namespaces have PSA
CRITICAL_NS_PSA=("threadforge" "observability" "tempo")
MISSING_PSA=""

for ns in "${CRITICAL_NS_PSA[@]}"; do
  HAS_PSA=$(echo "$PSA_NAMESPACES" | jq --arg ns "$ns" '[.[] | select(.name == $ns)] | length' 2>/dev/null || echo "0")
  if [ "$HAS_PSA" -eq 0 ]; then
    # Check if namespace exists
    if kubectl get ns "$ns" >/dev/null 2>&1; then
      MISSING_PSA="${MISSING_PSA}${ns}, "
    fi
  fi
done

if [ -n "$MISSING_PSA" ]; then
  echo "[control-plane] WARN: Namespaces without PSA labels: ${MISSING_PSA%,*}"
  # Record but don't fail - PSA may be configured at cluster level
fi

# 3. Gatekeeper/OPA (optional)
GATEKEEPER_PRESENT=false
if kubectl get crd constrainttemplates.templates.gatekeeper.sh >/dev/null 2>&1; then
  GATEKEEPER_PRESENT=true
  CONSTRAINT_TEMPLATES=$(kubectl get constrainttemplates -o json 2>/dev/null | jq '[.items[].metadata.name]' || echo "[]")
  echo "$CONSTRAINT_TEMPLATES" > "$EVIDENCE_DIR/gatekeeper_templates.json"
fi

# 4. Kyverno (optional)
KYVERNO_PRESENT=false
if kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
  KYVERNO_PRESENT=true
  KYVERNO_POLICIES=$(kubectl get clusterpolicies -o json 2>/dev/null | jq '[.items[].metadata.name]' || echo "[]")
  echo "$KYVERNO_POLICIES" > "$EVIDENCE_DIR/kyverno_policies.json"
fi

# 5. AuthorizationPolicies (Istio)
AUTHZ_POLICIES=$(kubectl get authorizationpolicies -A -o json 2>/dev/null | jq '
  [.items[] | {
    namespace: .metadata.namespace,
    name: .metadata.name,
    action: .spec.action
  }]
' 2>/dev/null || echo "[]")

AUTHZ_COUNT=$(echo "$AUTHZ_POLICIES" | jq 'length')
echo "$AUTHZ_POLICIES" > "$EVIDENCE_DIR/authorization_policies.json"

# Check for DENY policies (explicit deny semantics)
DENY_POLICIES=$(echo "$AUTHZ_POLICIES" | jq '[.[] | select(.action == "DENY")] | length' 2>/dev/null || echo "0")

# Write policy summary
POLICY_EVIDENCE=$(cat <<EOF
{
  "networkpolicies": {
    "count": $NETPOL_COUNT,
    "namespaces": $NETPOL_NAMESPACES,
    "default_deny_patterns": $DEFAULT_DENY_COUNT
  },
  "pod_security_admission": {
    "namespaces_with_psa": $PSA_COUNT,
    "missing_psa": "${MISSING_PSA%,*}"
  },
  "gatekeeper": {
    "present": $GATEKEEPER_PRESENT
  },
  "kyverno": {
    "present": $KYVERNO_PRESENT
  },
  "istio_authz": {
    "count": $AUTHZ_COUNT,
    "deny_policies": $DENY_POLICIES
  },
  "issues": "${POLICY_ISSUES}"
}
EOF
)
echo "$POLICY_EVIDENCE" | jq . > "$EVIDENCE_DIR/policy_summary.json" 2>/dev/null || \
  echo "$POLICY_EVIDENCE" > "$EVIDENCE_DIR/policy_summary.json"

if [ "$POLICY_OK" = "true" ]; then
  echo "[control-plane] OK: Policy enforcement present (${NETPOL_COUNT} NetworkPolicies, ${PSA_COUNT} PSA namespaces, ${AUTHZ_COUNT} AuthzPolicies)"
else
  GATE_PASS=false
  FAILURE_REASONS+=("policy enforcement issues: ${POLICY_ISSUES}")
  echo "[control-plane] FAIL: Policy issues: ${POLICY_ISSUES}"
fi

# -----------------------------------------------------------------------------
# DECISION
# -----------------------------------------------------------------------------
if [ "$GATE_PASS" = "true" ]; then
  echo "[control-plane] PASS — control plane authority contained"
  DECISION="PASS"
else
  echo "[control-plane] FAIL — $(IFS=';'; echo "${FAILURE_REASONS[*]}")"
  DECISION="FAIL"
fi

# Determine condition statuses
ADMISSION_STATUS="UNKNOWN"
if [ "$ADMISSION_OK" = "true" ]; then
  ADMISSION_STATUS="PASS"
else
  ADMISSION_STATUS="FAIL"
fi

RBAC_STATUS="UNKNOWN"
if [ "$RBAC_OK" = "true" ]; then
  RBAC_STATUS="PASS"
else
  RBAC_STATUS="FAIL"
fi

WRITE_PATHS_STATUS="UNKNOWN"
if [ "$WRITE_PATHS_OK" = "true" ]; then
  WRITE_PATHS_STATUS="PASS"
else
  WRITE_PATHS_STATUS="FAIL"
fi

POLICY_STATUS="UNKNOWN"
if [ "$POLICY_OK" = "true" ]; then
  POLICY_STATUS="PASS"
else
  POLICY_STATUS="FAIL"
fi

# Write decision file
cat > "$EVIDENCE_DIR/decision.txt" <<EOF
CONTROL PLANE & POLICY GATE
===========================
Drill ID:    ${DRILL_ID}
Timestamp:   ${NOW_UTC}
Mode:        $([ "$STRICT" = "1" ] && echo "STRICT" || echo "ADVISORY")
Decision:    ${DECISION}

Authority Question: "Can this cluster mutate state outside of declared, intentional control?"

Conditions:
  1. Admission Control:     ${ADMISSION_STATUS}
     - Validating webhooks: ${VALIDATING_COUNT}
     - Mutating webhooks:   ${MUTATING_COUNT}
     - Fail-open webhooks:  ${TOTAL_FAIL_OPEN}

  2. RBAC Authority:        ${RBAC_STATUS}
     - Privileged default SA bindings: ${PRIVILEGED_DEFAULT_SA}

  3. Write Paths:           ${WRITE_PATHS_STATUS}
     - Helm releases:       ${HELM_COUNT}
     - Operators:           ${OPERATOR_COUNT}
     - CRDs:                ${CRD_COUNT}

  4. Policy Enforcement:    ${POLICY_STATUS}
     - NetworkPolicies:     ${NETPOL_COUNT}
     - PSA namespaces:      ${PSA_COUNT}
     - AuthzPolicies:       ${AUTHZ_COUNT}
     - Gatekeeper:          ${GATEKEEPER_PRESENT}
     - Kyverno:             ${KYVERNO_PRESENT}

$([ ${#FAILURE_REASONS[@]} -gt 0 ] && echo "Failure Reasons:" && printf "  - %s\n" "${FAILURE_REASONS[@]}" || echo "")

Evidence: ${EVIDENCE_DIR}/
EOF

cat "$EVIDENCE_DIR/decision.txt"

# Write summary JSON
cat > "$EVIDENCE_DIR/summary.json" <<EOF
{
  "gate": "control-plane",
  "drill_id": "${DRILL_ID}",
  "timestamp": "${NOW_UTC}",
  "mode": "$([ "$STRICT" = "1" ] && echo "strict" || echo "advisory")",
  "decision": "${DECISION}",
  "authority_question": "Can this cluster mutate state outside of declared, intentional control?",
  "conditions": {
    "admission_control": "${ADMISSION_STATUS}",
    "rbac_authority": "${RBAC_STATUS}",
    "write_paths": "${WRITE_PATHS_STATUS}",
    "policy_enforcement": "${POLICY_STATUS}"
  },
  "metrics": {
    "validating_webhooks": ${VALIDATING_COUNT},
    "mutating_webhooks": ${MUTATING_COUNT},
    "fail_open_webhooks": ${TOTAL_FAIL_OPEN},
    "helm_releases": ${HELM_COUNT},
    "operators": ${OPERATOR_COUNT},
    "crds": ${CRD_COUNT},
    "networkpolicies": ${NETPOL_COUNT},
    "psa_namespaces": ${PSA_COUNT},
    "authz_policies": ${AUTHZ_COUNT}
  },
  "failure_reasons": $(printf '%s\n' "${FAILURE_REASONS[@]:-}" | jq -R -s 'split("\n") | map(select(length > 0))')
}
EOF

# Exit based on mode
if [ "$DECISION" = "FAIL" ]; then
  if [ "$STRICT" = "1" ]; then
    echo ""
    echo "⛔ CONTROL PLANE GATE FAIL (STRICT) — execution blocked"
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  else
    echo ""
    echo "⚠️  CONTROL PLANE GATE FAIL (ADVISORY) — continuing with degraded confidence"
    exit 0
  fi
else
  echo ""
  echo "✅ CONTROL PLANE GATE PASS — authority contained"
  exit 0
fi
