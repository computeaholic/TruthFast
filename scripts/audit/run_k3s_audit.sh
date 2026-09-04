#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  cat <<EOF
Usage: $0 <mode> [arg]

Modes:
  deploy <version>
  runtime
  full
  integrity
  estimate
  guard
  metrics
  disk-guard
  offload
  emergency
  etcd-check
  upgrade-gate
  seal
  pre-upgrade
  rotation-chain
  verify-chain
  continuity
  ledger-seal
  external-anchor
  attest [private-key]
  attest-verify [public-key]
  export
  experimental-identity-revocation
  experimental-rbac-escalation
  experimental-disable-attempt
  experimental-hostile-check
  experimental-signal-hygiene
EOF
}

if [[ $# -lt 1 ]]; then
  usage >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

mode="$1"
shift || true

if [[ -z "${mode:-}" ]]; then
  echo "ERROR: mode required" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "[k3s-audit] mode=$mode"

run_script() {
  exec bash "$@"
}

case "$mode" in
  deploy)
    version="${1:-v1}"
    run_script "$REPO_ROOT/scripts/install/deploy_k3s_audit_policy.sh" "$version"
    ;;
  runtime)
    run_script "$REPO_ROOT/scripts/advisory/validate_k3s_audit_runtime.sh"
    ;;
  full)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_full_validation.sh"
    ;;
  integrity)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_integrity_lock.sh"
    ;;
  estimate)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/estimate_audit_growth.sh"
    ;;
  guard)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_log_guard.sh"
    ;;
  metrics)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/metrics/audit_metrics_exporter.sh"
    ;;
  disk-guard)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_disk_pressure_guard.sh"
    ;;
  offload)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_s3_offload.sh"
    ;;
  emergency)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_emergency_mode.sh"
    ;;
  etcd-check)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_etcd_correlation.sh"
    ;;
  upgrade-gate)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_upgrade_gate.sh"
    ;;
  seal)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_baseline_seal.sh"
    ;;
  pre-upgrade)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_pre_upgrade_check.sh"
    ;;
  rotation-chain)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_rotation_chain.sh"
    ;;
  verify-chain)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_verify_rotation_chain.sh"
    ;;
  continuity)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_continuity_check.sh"
    ;;
  ledger-seal)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_ledger_seal.sh"
    ;;
  external-anchor)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_external_anchor.sh"
    ;;
  attest)
    private_key="${1:-}"
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_external_attest.sh" \
      --ledger "$REPO_ROOT/platform/deploy/infra/k3s/audit/AUDIT_ROTATION_LEDGER.jsonl" \
      --seal "$REPO_ROOT/platform/deploy/infra/k3s/audit/AUDIT_LEDGER_SEAL.json" \
      --output "$REPO_ROOT/platform/deploy/infra/k3s/audit/AUDIT_EXTERNAL_ATTESTATION.json" \
      --private-key "$private_key"
    ;;
  attest-verify)
    public_key="${1:-}"
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_attestation_verify.sh" \
      --attestation "$REPO_ROOT/platform/deploy/infra/k3s/audit/AUDIT_EXTERNAL_ATTESTATION.json" \
      --signature "$REPO_ROOT/platform/deploy/infra/k3s/audit/AUDIT_EXTERNAL_ATTESTATION.json.sig" \
      --public-key "$public_key"
    ;;
  export)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_export_snapshot.sh"
    ;;
  experimental-identity-revocation)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_identity_revocation_test.sh"
    ;;
  experimental-rbac-escalation)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_rbac_escalation_test.sh"
    ;;
  experimental-disable-attempt)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_disable_attempt_test.sh"
    ;;
  experimental-hostile-check)
    run_script "$REPO_ROOT/platform/deploy/infra/k3s/audit/scripts/audit_hostile_review_check.sh"
    ;;
  experimental-signal-hygiene)
    run_script "$REPO_ROOT/scripts/debug/audit-signal-hygiene.sh"
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    usage >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    ;;
esac
