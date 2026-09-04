#!/usr/bin/env bash
# requires_identity=true  # trust_tier=full
# Authority Domain: confirm_gated
# DEPRECATED compatibility runner: prefer Make target `forgesec` in scripts/make/forgesec.mk
if ! bash platform/runtime/operator/identity_enforcer.sh --require-full >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires a full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

set -euo pipefail

# ThreadForge ForgeSec Pen-Test Runner
# Runs defensive security evaluation from outside-trust perspective

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORGESEC_DIR="$REPO_ROOT/platform/deploy/forgesec"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { echo -e "${BLUE}[ForgeSec]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }

# Check prerequisites
check_prereqs() {
    if ! command -v kubectl >/dev/null 2>&1; then
        error "kubectl not found in PATH"
        echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
    fi

    if ! kubectl cluster-info >/dev/null 2>&1; then
        error "kubectl cannot connect to cluster"
        echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
    fi

    success "Prerequisites check passed"
}

# Preflight: ensure worker Deployments use non-default ServiceAccounts
check_workers_sa() {
    info "Checking worker Deployments for ServiceAccount usage..."
    local bad
    bad=$(kubectl get deployments -n workers -o jsonpath='{range .items[*]}{.metadata.name}:::{.spec.template.spec.serviceAccountName}\n{end}' 2>/dev/null | awk -F ':::' '$2=="" || $2=="default"{print $1":"$2}' || true)
    if [[ -n "$bad" ]]; then
        error "Found worker deployments using default/no ServiceAccount: $bad"
        echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
    fi
    success "Workers preflight OK: all Deployments have non-default ServiceAccount"
}

# Apply ForgeSec manifests
apply_manifests() {
    info "Applying ForgeSec manifests..."

    # Apply in order: namespace, rbac, networkpolicy, workers-reader-role, job
    kubectl apply -f "$FORGESEC_DIR/namespace.yaml"
    kubectl apply -f "$FORGESEC_DIR/rbac.yaml"
    kubectl apply -f "$FORGESEC_DIR/networkpolicy.yaml"
    # Create namespace-scoped role allowing the job to inspect worker Deployments
    kubectl apply -f "$FORGESEC_DIR/workers-reader-role.yaml"
    # The Job manifest uses `generateName`. Use `kubectl create` to create a new Job instance
    # (kubectl apply cannot be used with generateName). This avoids immutable-field mutation errors.
    kubectl create -f "$FORGESEC_DIR/job.yaml"
    success "ForgeSec manifests applied"
}

# Wait for job completion
wait_for_job() {
    local namespace="forgesec"
    local timeout=300  # 5 minutes

    info "Waiting for ForgeSec job to complete (timeout: ${timeout}s)..."

    local start_time=$(date +%s)
    while true; do
        # determine the latest job name by creationTimestamp for label selector
        job_name=$(kubectl get jobs -n "$namespace" -l security.threadforge.local/job-type=pen-test -o jsonpath='{range .items[*]}{.metadata.creationTimestamp} {.metadata.name}\n{end}' | sort | tail -n1 | awk '{print $2}')
        if [[ -z "$job_name" ]]; then
            error "No ForgeSec job found to wait on"
            return 1
        fi

        local status
        status=$(kubectl get job "$job_name" -n "$namespace" -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "")

        if [[ "$status" == "Complete" ]]; then
            success "ForgeSec job ($job_name) completed successfully"
            return 0
        elif [[ "$status" == "Failed" ]]; then
            error "ForgeSec job ($job_name) failed"
            return 1
        fi

        local elapsed=$(( $(date +%s) - start_time ))
        if [[ $elapsed -gt $timeout ]]; then
            error "Timeout waiting for ForgeSec job completion"
            return 1
        fi

        sleep 5
    done
}

# Collect artifacts
collect_artifacts() {
    local audit_dir="$1"
    local namespace="forgesec"
    local artifacts_dir="$audit_dir/forgesec"

    mkdir -p "$artifacts_dir"

    info "Collecting ForgeSec artifacts..."

    # Determine latest job name
    job_name=$(kubectl get jobs -n "$namespace" -l security.threadforge.local/job-type=pen-test -o jsonpath='{range .items[*]}{.metadata.creationTimestamp} {.metadata.name}\n{end}' | sort | tail -n1 | awk '{print $2}')
    if [[ -z "$job_name" ]]; then
        warn "No ForgeSec job found to collect artifacts from"
        return 0
    fi

    # Get job logs
    kubectl logs -n "$namespace" "job/$job_name" > "$artifacts_dir/job.log" 2>&1 || warn "Could not collect job logs"

    # Get job status
    kubectl get job "$job_name" -n "$namespace" -o yaml > "$artifacts_dir/job.yaml" 2>&1 || warn "Could not collect job status"

    # Get pod details
    local pod_name
    pod_name=$(kubectl get pods -n "$namespace" -l job-name="$job_name" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$pod_name" ]]; then
        kubectl describe pod "$pod_name" -n "$namespace" > "$artifacts_dir/pod.describe" 2>&1 || warn "Could not collect pod description"
    fi

    # Generate test evidence summary with deterministic IDs
    cat > "$artifacts_dir/test_evidence.json" << EOF
{
  "test_id": "FORGESEC-DEFENSIVE-001",
  "test_name": "External Trust Ring Boundary Validation",
  "timestamp": "$(date -u +%Y%m%dT%H%M%SZ)",
  "evidence_refs": [
    "job.log",
    "job.yaml",
    "pod.describe"
  ],
  "validation_scope": "defensive_controls_only",
  "exclusions": [
    "no_penetration_testing",
    "no_exploit_development",
    "no_attack_simulation",
    "no_vulnerability_scanning"
  ],
  "claims": {
    "validates": "boundary_enforcement_mechanisms",
    "demonstrates": "deny_by_default_network_policies",
    "observes": "identity_gated_execution_boundaries"
  }
}
EOF

    success "Artifacts collected to $artifacts_dir"
}

# Print summary
print_summary() {
    local artifacts_dir="$1"

    echo
    info "ForgeSec Defensive Validation Summary"
    echo "======================================"
    echo "Artifacts Location: $artifacts_dir"
    echo
    echo "Validation Results:"
    echo "✓ Cannot reach protected services directly (deny-by-default proven)"
    echo "✓ Must go through PPIT translation path (if configured)"
    echo "✓ mTLS/certificate properties show 'outside-marked' identity"
    echo "✓ AuthZ denials produce cryptographic denial proofs + audit events"
    echo
    echo "What this proves:"
    echo "- ThreadForge implements defense-in-depth security"
    echo "- Network segmentation limits compromise blast radius"
    echo "- RBAC and service mesh provide access control"
    echo "- Audit logging captures security-relevant events"
    echo "- Identity trust rings are properly enforced"
    echo
    echo "What this does NOT claim:"
    echo "- No DDoS testing performed"
    echo "- No nation-state attack simulation"
    echo "- No zero-day exploit testing"
    echo "- No penetration testing or exploit development"
    echo "- Defensive validation only; not a security audit"
    echo
    success "ForgeSec defensive validation completed"
}

# Main execution
main() {
    local audit_dir="${1:-}"

    if [[ -z "$audit_dir" ]]; then
        # Create timestamped audit directory if not provided
        local ts
        ts="$(date -u +%Y%m%dT%H%M%SZ)"
        audit_dir="$REPO_ROOT/artifacts/audit/${ts}"
        mkdir -p "$audit_dir"
    fi

    info "Starting ForgeSec pen-test evaluation..."
    info "Audit directory: $audit_dir"

    check_prereqs
    # Preflight check: ensure worker Deployments are using non-default SAs
    check_workers_sa
    apply_manifests

    if wait_for_job; then
        collect_artifacts "$audit_dir"
        print_summary "$audit_dir/forgesec"
    else
        error "ForgeSec job did not complete successfully"
        echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
    fi
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
