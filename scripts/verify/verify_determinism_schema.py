import json
import sys
from pathlib import Path

STATUS_PATH = Path("artifacts/proof/status.json")

ALLOWED_KEYS = {
    "active_guarantees",
    "passive_guarantees",
    "admission_rejection",
    "advisory_count",
    "artifacts_verified",
    "blocked_guarantees",
    "bootstrap",
    "cert_rotation_continuity",
    "closed_loop",
    "cluster_id",
    "cluster_integrity",
    "completion_record",
    "contracts",
    "determinism_verified",
    "digest_identity_enforced",
    "drift_detected",
    "east_west_isolation",
    "envoy_identity",
    "ephemeral_containers_blocked",
    "evidence",
    "existing_session_fail_closed",
    "exit_semantics_consistent",
    "fail_class",
    "final",
    "guarantees",
    "identity",
    "identity_root",
    "image_policy",
    "image_signing",
    "injected_images_locked",
    "mesh_baseline",
    "mode",
    "no_istio_ca_fallback",
    "north_south_boundary",
    "rbac_resolution",
    "audit_logging",
    "tenant_isolation",
    "not_evaluated_guarantees",
    "observability",
    "observability_prereq",
    "observability_required",
    "observe",
    "observe_reason",
    "phase_exit_codes",
    "phases_all_pass",
    "proof_result",
    "proof_heals_canonical_state",
    "proof_mutation_mode",
    "read_only_guarantees",
    "reasons",
    "registry_tls_trust",
    "registry_completeness",
    "runtime_identity_verified",
    "service_topology",
    "sidecar_enforcement",
    "signed",
    "strict_mode",
    "trust_root_immutability",
    "verified",
    "verify",
}

REQUIRED_KEYS = {
    "final",
    "fail_class",
    "determinism_verified",
    "signed",
    "verified",
    "verify",
    "observe",
}

def validate_status(data: dict) -> tuple[list[str], list[str]]:
    unknown = sorted(set(data.keys()) - ALLOWED_KEYS)
    missing = sorted(REQUIRED_KEYS - set(data.keys()))
    return missing, unknown


def main() -> int:
    if not STATUS_PATH.is_file():
        print(f"[FAIL] STATUS_FILE_MISSING: {STATUS_PATH}")
        return 2

    with STATUS_PATH.open() as f:
        data = json.load(f)

    missing, unknown = validate_status(data)
    if missing:
        print("[FAIL] MISSING_STATUS_FIELDS:", missing)
        return 2
    if unknown:
        print("[FAIL] UNKNOWN_STATUS_FIELDS:", unknown)
        return 2

    print("[PASS] STATUS_SCHEMA_VALID")
    return 0


if __name__ == "__main__":
    sys.exit(main())
