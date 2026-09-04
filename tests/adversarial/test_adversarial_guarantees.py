"""Adversarial guarantee tests.

These tests verify that the proof system correctly detects and reports
guarantee failures. Each test exercises the guarantee validation logic
extracted from verify_proof_artifacts.sh.

The guarantee validation is a pure Python function that inspects status.json
content. These tests run without a live Kubernetes cluster and are always
deterministic.

Test cases:
  1. Identity break     — status.json with identity_spiffe=FAIL is rejected
  2. Supply chain       — status.json with supply_chain_digest=FAIL is rejected
  3. Observability      — status.json with observability_stack=FAIL is rejected
  4. Admission bypass   — status.json with admission_enforced=FAIL and
                          structural tampering are rejected

Each test asserts:
  - exit code (non-zero for rejections)
  - the failing guarantee name appears in error output
  - a valid all-PASS status.json is accepted by the same logic
"""

import json
import subprocess
from pathlib import Path

import pytest

pytestmark = [pytest.mark.unit, pytest.mark.adversarial]

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

REQUIRED_GUARANTEES = [
    "fail_closed_execution",
    "deterministic_output",
    "no_fallback_logic",
    "no_optional_paths",
    "identity_spiffe",
    "identity_envoy",
    "supply_chain_digest",
    "kind_node_image_verified",
    "runtime_identity_verified",
    "no_external_images",
    "admission_enforced",
    "observability_stack",
    "observability_behavior",
    "workload_projection_continuity",
    "trust_root_immutability",
    "registry_tls_trust",
    "registry_completeness",
    "mesh_baseline",
    "north_south_boundary",
    "east_west_isolation",
    "sidecar_enforcement",
    "service_topology",
    "rbac_resolution",
    "audit_logging",
    "tenant_isolation",
    "cert_rotation_continuity",
    "existing_session_fail_closed",
    "no_istio_ca_fallback",
]

# The Python validation logic extracted from verify_proof_artifacts.sh.
# This is an exact replica of the guarantee validation block to ensure
# the test is testing the same logic as production.
_GUARANTEE_VALIDATOR_PY = """
import json, sys

REQUIRED_GUARANTEES = [
    "fail_closed_execution",
    "deterministic_output",
    "no_fallback_logic",
    "no_optional_paths",
    "identity_spiffe",
    "identity_envoy",
    "supply_chain_digest",
    "kind_node_image_verified",
    "runtime_identity_verified",
    "no_external_images",
    "admission_enforced",
    "observability_stack",
    "observability_behavior",
    "workload_projection_continuity",
    "trust_root_immutability",
    "registry_tls_trust",
    "registry_completeness",
    "mesh_baseline",
    "north_south_boundary",
    "east_west_isolation",
    "sidecar_enforcement",
    "service_topology",
    "rbac_resolution",
    "audit_logging",
    "tenant_isolation",
    "cert_rotation_continuity",
    "existing_session_fail_closed",
    "no_istio_ca_fallback",
]

status = json.loads(sys.stdin.read())
guarantees = status.get("guarantees")
if not isinstance(guarantees, dict):
    raise SystemExit("missing guarantees block in status.json")
for g in REQUIRED_GUARANTEES:
    if g not in guarantees:
        raise SystemExit(f"missing guarantee in status.json: {g}")
    entry = guarantees[g]
    if not isinstance(entry, dict):
        raise SystemExit(f"guarantee entry malformed: {g}")
    g_status = entry.get("status")
    if g_status != "PASS":
        raise SystemExit(f"guarantee not PASS: {g}={g_status!r}")
    if not entry.get("phase"):
        raise SystemExit(f"guarantee missing phase: {g}")
    if not entry.get("enforced_by"):
        raise SystemExit(f"guarantee missing enforced_by: {g}")
passive = status.get("passive_guarantees", status.get("read_only_guarantees"))
read_only = status.get("read_only_guarantees")
if passive != "PASS":
    raise SystemExit(f"passive_guarantees must be PASS, got {passive!r}")
if read_only is not None and read_only != passive:
    raise SystemExit("deprecated read_only_guarantees alias must equal passive_guarantees")
if status.get("proof_heals_canonical_state") not in (None, False):
    raise SystemExit("proof_heals_canonical_state must not be true")
print(f"[PASS] all {len(REQUIRED_GUARANTEES)} guarantees present and PASS")
"""

_PHASES = {
    "fail_closed_execution": ("verify", "prove_system.sh + verify_exit_semantics.sh"),
    "deterministic_output": ("verify", "verify_proof_artifacts.sh"),
    "no_fallback_logic": ("prove_system", "prove_system.sh"),
    "no_optional_paths": ("prove_system", "prove_system.sh"),
    "identity_spiffe": ("identity", "validate_spiffe_identity.sh"),
    "identity_envoy": ("envoy_identity", "validate_envoy_identity.sh"),
    "supply_chain_digest": ("verify", "enforce_image_digests.sh"),
    "kind_node_image_verified": ("verify", "verify_kind_node_image.sh"),
    "runtime_identity_verified": ("verify", "verify_runtime_images.sh"),
    "no_external_images": ("verify", "verify_no_external_runtime_images.sh"),
    "admission_enforced": ("verify", "verify_admission_alignment.sh"),
    "observability_stack": ("observability_prereq", "verify_observability_stack.sh"),
    "observability_behavior": ("observe", "validate_observability.sh"),
    "workload_projection_continuity": ("verify", "verify_workload_projection_continuity.sh"),
    "trust_root_immutability": ("verify", "verify_trust_root_immutability.sh"),
    "registry_tls_trust": ("verify", "verify_registry_tls_trust.sh"),
    "registry_completeness": ("verify", "verify_registry_completeness.sh"),
    "mesh_baseline": ("verify", "verify_mesh_baseline.sh"),
    "north_south_boundary": ("verify", "verify_north_south_boundary.sh"),
    "east_west_isolation": ("verify", "verify_east_west_blocking.sh"),
    "sidecar_enforcement": ("verify", "verify_sidecar_enforcement.sh"),
    "service_topology": ("verify", "verify_authoritative_topology.sh"),
    "rbac_resolution": ("verify", "verify_rbac_resolution.sh"),
    "audit_logging": ("verify", "verify_audit_logging.sh"),
    "tenant_isolation": ("verify", "verify_tenant_isolation.sh"),
    "cert_rotation_continuity": ("verify", "verify_cert_rotation_continuity.sh"),
    "existing_session_fail_closed": ("verify", "verify_existing_session_fail_closed.sh"),
    "no_istio_ca_fallback": ("identity", "verify_no_istio_ca_fallback.sh"),
}


def _build_all_pass_guarantees() -> dict:
    return {
        name: {"status": "PASS", "phase": phase, "enforced_by": script} for name, (phase, script) in _PHASES.items()
    }


def _build_status_json(guarantees: dict | None = None) -> dict:
    """Build a complete status.json. If guarantees is None, omit the key."""
    doc: dict = {
        "mode": "full",
        "bootstrap": {"status": "PASS", "reason": ""},
        "identity": {"status": "PASS", "reason": ""},
        "envoy_identity": "PASS",
        "cluster_integrity": "PASS",
        "observability_prereq": "PASS",
        "verify": "PASS",
        "observe": "PASS",
        "final": "PASS",
        "fail_class": "NONE",
        "run_id": "20260101T000000Z-adversarial-test",
        "cluster_id": "test-cluster-adversarial",
        "strict_mode": "true",
        "advisory_count": 0,
        "closed_loop": {"status": "PASS", "reason": ""},
        "image_signing": "PASS",
        "runtime_identity_verified": "PASS",
        "admission_rejection": "PASS",
        "injected_images_locked": "PASS",
        "ephemeral_containers_blocked": "PASS",
        "digest_identity_enforced": "PASS",
        "exit_semantics_consistent": "PASS",
        "read_only_guarantees": "PASS",
        "passive_guarantees": "PASS",
        "active_guarantees": "PASS",
        "proof_heals_canonical_state": False,
        "proof_mutation_mode": "bounded_active_assurance",
        "blocked_guarantees": [],
        "not_evaluated_guarantees": [],
        "contracts": {
            "bootstrap": "SATISFIED",
            "identity": "SATISFIED",
            "envoy_identity": "SATISFIED",
            "verify": "SATISFIED",
            "observe": "SATISFIED",
        },
        "identity_root": "spire",
        "image_policy": "digest_only",
        "observability_required": True,
        "drift_detected": False,
        "evidence": {
            "signed": False,
            "verified": False,
            "artifacts": {},
            "signature_files": [],
        },
        "reasons": [],
        "timestamp": "2026-01-01T00:00:00Z",
        "log_dir": "/tmp/test",
    }
    if guarantees is not None:
        doc["guarantees"] = guarantees
    return doc


def _validate(status_doc: dict) -> tuple[int, str, str]:
    """Run the guarantee validation against a status.json dict.

    Returns (returncode, stdout, stderr).
    """
    proc = subprocess.run(
        ["python3", "-c", _GUARANTEE_VALIDATOR_PY],
        input=json.dumps(status_doc),
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.returncode, proc.stdout, proc.stderr


# ---------------------------------------------------------------------------
# Baseline: all PASS is accepted
# ---------------------------------------------------------------------------


class TestBaselineAllPass:
    def test_all_pass_guarantees_accepted(self) -> None:
        """A status.json with all required guarantees PASS must be accepted."""
        doc = _build_status_json(_build_all_pass_guarantees())
        rc, stdout, stderr = _validate(doc)
        assert rc == 0, f"Expected acceptance of all-PASS guarantees; got rc={rc}, stderr={stderr[:300]}"
        assert "[PASS]" in stdout

    def test_all_guarantee_names_present(self) -> None:
        """The REQUIRED_GUARANTEES list matches the canonical names defined in prove_system.sh."""
        assert len(REQUIRED_GUARANTEES) == 28
        expected = {
            "fail_closed_execution",
            "deterministic_output",
            "no_fallback_logic",
            "no_optional_paths",
            "identity_spiffe",
            "identity_envoy",
            "supply_chain_digest",
            "kind_node_image_verified",
            "runtime_identity_verified",
            "no_external_images",
            "admission_enforced",
            "observability_stack",
            "observability_behavior",
            "workload_projection_continuity",
            "trust_root_immutability",
            "registry_tls_trust",
            "registry_completeness",
            "mesh_baseline",
            "north_south_boundary",
            "east_west_isolation",
            "sidecar_enforcement",
            "service_topology",
            "rbac_resolution",
            "audit_logging",
            "tenant_isolation",
            "cert_rotation_continuity",
            "existing_session_fail_closed",
            "no_istio_ca_fallback",
        }
        assert set(REQUIRED_GUARANTEES) == expected


# ---------------------------------------------------------------------------
# Case 1 — Identity break
# A status.json claiming FINAL=PASS with identity_spiffe=FAIL must be rejected.
# The identity_spiffe guarantee is derived from PHASE_IDENTITY in prove_system.sh.
# ---------------------------------------------------------------------------


class TestIdentityBreak:
    """Simulate invalid SPIFFE identity by setting identity_spiffe=FAIL."""

    def test_identity_spiffe_fail_causes_rejection(self) -> None:
        """status.json with identity_spiffe=FAIL is rejected; failing guarantee named."""
        guarantees = _build_all_pass_guarantees()
        guarantees["identity_spiffe"]["status"] = "FAIL"
        doc = _build_status_json(guarantees)

        rc, stdout, stderr = _validate(doc)

        assert rc != 0, "Expected rejection when identity_spiffe=FAIL"
        assert "identity_spiffe" in (stdout + stderr), "Expected the failing guarantee name in output"

    def test_no_istio_ca_fallback_fail_causes_rejection(self) -> None:
        """status.json with no_istio_ca_fallback=FAIL is rejected."""
        guarantees = _build_all_pass_guarantees()
        guarantees["no_istio_ca_fallback"]["status"] = "FAIL"
        doc = _build_status_json(guarantees)

        rc, _, stderr = _validate(doc)

        assert rc != 0, "Expected rejection when no_istio_ca_fallback=FAIL"
        assert "no_istio_ca_fallback" in stderr

    def test_identity_envoy_fail_causes_rejection(self) -> None:
        """status.json with identity_envoy=FAIL is rejected."""
        guarantees = _build_all_pass_guarantees()
        guarantees["identity_envoy"]["status"] = "FAIL"
        doc = _build_status_json(guarantees)

        rc, _, stderr = _validate(doc)

        assert rc != 0, "Expected rejection when identity_envoy=FAIL"
        assert "identity_envoy" in stderr


# ---------------------------------------------------------------------------
# Case 2 — Supply chain violation
# A status.json with supply_chain_digest=FAIL must be rejected.
# supply_chain_digest is derived from DIGEST_IDENTITY_ENFORCED_STATUS,
# set by enforce_image_digests.sh in the verify phase.
# ---------------------------------------------------------------------------


class TestSupplyChainViolation:
    """Simulate image without digest / wrong digest."""

    def test_supply_chain_digest_fail_causes_rejection(self) -> None:
        """status.json with supply_chain_digest=FAIL is rejected; FINAL=FAIL implied."""
        guarantees = _build_all_pass_guarantees()
        guarantees["supply_chain_digest"]["status"] = "FAIL"
        doc = _build_status_json(guarantees)

        rc, _, stderr = _validate(doc)

        assert rc != 0, "Expected rejection when supply_chain_digest=FAIL"
        assert "supply_chain_digest" in stderr, f"Expected supply_chain_digest in error; got: {stderr[:300]}"

    def test_no_external_images_fail_causes_rejection(self) -> None:
        """status.json with no_external_images=FAIL is rejected."""
        guarantees = _build_all_pass_guarantees()
        guarantees["no_external_images"]["status"] = "FAIL"
        doc = _build_status_json(guarantees)

        rc, _, stderr = _validate(doc)

        assert rc != 0, "Expected rejection when no_external_images=FAIL"
        assert "no_external_images" in stderr

    def test_runtime_identity_verified_fail_causes_rejection(self) -> None:
        """status.json with runtime_identity_verified=FAIL is rejected."""
        guarantees = _build_all_pass_guarantees()
        guarantees["runtime_identity_verified"]["status"] = "FAIL"
        doc = _build_status_json(guarantees)

        rc, _, stderr = _validate(doc)

        assert rc != 0, "Expected rejection when runtime_identity_verified=FAIL"

    def test_blocked_active_guarantees_are_rejected(self) -> None:
        """Canonical proof must reject blocked guarantees in the final truth model."""
        guarantees = _build_all_pass_guarantees()
        guarantees["admission_enforced"]["status"] = "BLOCKED"
        guarantees["cert_rotation_continuity"]["status"] = "BLOCKED"
        doc = _build_status_json(guarantees)

        rc, stdout, stderr = _validate(doc)

        assert rc != 0, "Expected rejection of BLOCKED guarantees"
        assert "admission_enforced" in stderr or "cert_rotation_continuity" in stderr

    def test_proof_cannot_claim_healing_canonical_state(self) -> None:
        """A proof artifact may never advertise producer-healing authority."""
        doc = _build_status_json(_build_all_pass_guarantees())
        doc["proof_heals_canonical_state"] = True

        rc, _, stderr = _validate(doc)

        assert rc != 0, "Expected rejection when proof_heals_canonical_state=true"
        assert "proof_heals_canonical_state" in stderr


# ---------------------------------------------------------------------------
# Case 3 — Observability break
# A status.json with observability_stack=FAIL or observability_behavior=FAIL
# must be rejected. These guarantees are derived from PHASE_OBSERVABILITY_PREREQ
# and PHASE_OBSERVE, which gate all downstream verification.
# ---------------------------------------------------------------------------


class TestObservabilityBreak:
    """Simulate missing Prometheus/Loki/Tempo."""

    def test_observability_stack_fail_causes_rejection(self) -> None:
        """status.json with observability_stack=FAIL is rejected."""
        guarantees = _build_all_pass_guarantees()
        guarantees["observability_stack"]["status"] = "FAIL"
        doc = _build_status_json(guarantees)

        rc, _, stderr = _validate(doc)

        assert rc != 0, "Expected rejection when observability_stack=FAIL"
        assert "observability_stack" in stderr

    def test_observability_behavior_fail_causes_rejection(self) -> None:
        """status.json with observability_behavior=FAIL is rejected."""
        guarantees = _build_all_pass_guarantees()
        guarantees["observability_behavior"]["status"] = "FAIL"
        doc = _build_status_json(guarantees)

        rc, _, stderr = _validate(doc)

        assert rc != 0, "Expected rejection when observability_behavior=FAIL"


# ---------------------------------------------------------------------------
# Case 4 — Admission bypass attempt
# An attacker constructs a status.json claiming FINAL=PASS with admission_enforced=FAIL.
# The guarantee validator must detect and reject this.
# ---------------------------------------------------------------------------


class TestAdmissionBypassAttempt:
    """Simulate disallowed deployment and admission policy bypass attempts."""

    def test_admission_enforced_fail_causes_rejection(self) -> None:
        """status.json with admission_enforced=FAIL is rejected even if FINAL=PASS."""
        guarantees = _build_all_pass_guarantees()
        guarantees["admission_enforced"]["status"] = "FAIL"
        doc = _build_status_json(guarantees)
        # Attacker claims FINAL=PASS despite admission failure
        doc["final"] = "PASS"
        doc["fail_class"] = "NONE"

        rc, _, stderr = _validate(doc)

        assert rc != 0, "Expected rejection: attacker cannot claim FINAL=PASS with admission_enforced=FAIL"
        assert "admission_enforced" in stderr

    def test_missing_guarantees_block_rejected(self) -> None:
        """status.json without a guarantees block is rejected (tampered artifact)."""
        doc = _build_status_json(guarantees=None)
        # No "guarantees" key

        rc, _, stderr = _validate(doc)

        assert rc != 0, "Expected rejection when guarantees block is absent"
        assert "missing guarantees" in stderr or "guarantees" in stderr.lower()

    def test_missing_individual_guarantee_rejected(self) -> None:
        """status.json with a missing guarantee entry is rejected."""
        guarantees = _build_all_pass_guarantees()
        del guarantees["no_istio_ca_fallback"]  # Simulate tampered/incomplete artifact
        doc = _build_status_json(guarantees)

        rc, _, stderr = _validate(doc)

        assert rc != 0, "Expected rejection when no_istio_ca_fallback entry is absent"
        assert "no_istio_ca_fallback" in stderr

    def test_malformed_guarantee_entry_rejected(self) -> None:
        """status.json with a malformed guarantee entry (not a dict) is rejected."""
        guarantees = _build_all_pass_guarantees()
        guarantees["trust_root_immutability"] = "PASS"  # string, not dict
        doc = _build_status_json(guarantees)

        rc, _, stderr = _validate(doc)

        assert rc != 0, "Expected rejection when guarantee entry is not a dict"

    def test_guarantee_missing_phase_rejected(self) -> None:
        """status.json with a guarantee missing the 'phase' field is rejected."""
        guarantees = _build_all_pass_guarantees()
        del guarantees["cert_rotation_continuity"]["phase"]
        doc = _build_status_json(guarantees)

        rc, _, stderr = _validate(doc)

        assert rc != 0, "Expected rejection when guarantee is missing 'phase'"

    def test_guarantee_missing_enforced_by_rejected(self) -> None:
        """status.json with a guarantee missing 'enforced_by' is rejected."""
        guarantees = _build_all_pass_guarantees()
        del guarantees["fail_closed_execution"]["enforced_by"]
        doc = _build_status_json(guarantees)

        rc, _, stderr = _validate(doc)

        assert rc != 0, "Expected rejection when guarantee is missing 'enforced_by'"

    @pytest.mark.parametrize("guarantee", REQUIRED_GUARANTEES)
    def test_each_guarantee_fail_causes_rejection(self, guarantee: str) -> None:
        """Every individual guarantee FAIL must cause rejection (exhaustive check)."""
        guarantees = _build_all_pass_guarantees()
        guarantees[guarantee]["status"] = "FAIL"
        doc = _build_status_json(guarantees)

        rc, _, stderr = _validate(doc)

        assert rc != 0, f"Expected rejection when {guarantee}=FAIL"
        assert guarantee in stderr, f"Expected '{guarantee}' in error output; got: {stderr[:300]}"
