from __future__ import annotations

import json
from pathlib import Path

from scripts.proof import proof_hardening as ph


def test_projection_existing_session_semantic_strips_volatile_fields() -> None:
    raw = json.dumps(
        {
            "spire_outage": "policy_blocked",
            "existing_session": "not_tested",
            "fresh_request_after_expiry": "not_tested",
            "reason": "scale_to_zero_denied_by_policy",
            "pod_before": "test-client-abc123",
            "cert_before": {
                "serial": "deadbeef",
                "valid_from": "2026-05-23T20:00:00Z",
                "expiration_time": "2026-05-23T20:01:00Z",
            },
            "fresh_request": {"successful": False, "output": "HTTP_CODE=403"},
        }
    ).encode("utf-8")

    projected = ph._project_artifact(raw, "existing_session_semantic")

    assert projected == {
        "spire_outage": "policy_blocked",
        "existing_session": "not_tested",
        "fresh_request_after_expiry": "not_tested",
        "reason": "scale_to_zero_denied_by_policy",
        "fresh_request_successful": False,
    }


def test_projection_workload_spire_issuer_semantic_drops_pod_and_sorts() -> None:
    raw = json.dumps(
        {
            "status": "PASS",
            "active_spire_root_serial": "abc",
            "workload_count": 2,
            "workloads": [
                {
                    "namespace": "z",
                    "pod": "z-pod-123",
                    "spiffe_id": "spiffe://id/z",
                    "issuer": "CN=spire",
                    "runtime_ca_serial": "11",
                    "status": "PASS",
                },
                {
                    "namespace": "a",
                    "pod": "a-pod-999",
                    "spiffe_id": "spiffe://id/a",
                    "issuer": "CN=spire",
                    "runtime_ca_serial": "11",
                    "status": "PASS",
                },
            ],
        }
    ).encode("utf-8")

    projected = ph._project_artifact(raw, "workload_spire_issuer_semantic")

    assert projected["workload_count"] == 2
    assert projected["workloads"][0]["namespace"] == "a"
    assert all("pod" not in entry for entry in projected["workloads"])


def test_canonical_inventory_path_points_at_config_location() -> None:
    path = ph.CANONICAL_INVENTORY_PATH

    assert path.as_posix().endswith("artifacts/config/canonical_artifact_inventory.json")
    assert path.is_file()


def test_compare_with_canonical_inventory_classifies_operational_drift(monkeypatch, tmp_path: Path) -> None:
    run1 = tmp_path / "run1" / "latest"
    run2 = tmp_path / "run2" / "latest"
    run1.mkdir(parents=True)
    run2.mkdir(parents=True)

    # Canonical required artifacts are semantically identical after projection.
    status = {
        "final": "PASS",
        "proof_result": "PASS",
        "fail_class": "NONE",
        "read_only_guarantees": "PASS",
        "active_guarantees": "PASS",
        "admission_rejection": "PASS",
        "injected_images_locked": "PASS",
        "ephemeral_containers_blocked": "PASS",
        "exit_semantics_consistent": "PASS",
    }
    (run1 / "status.json").write_text(json.dumps(status) + "\n", encoding="utf-8")
    (run2 / "status.json").write_text(json.dumps(status) + "\n", encoding="utf-8")

    det1 = {"consistent": True, "fail_class": "NONE", "method": "artifact_integrity", "artifact_count": 27}
    det2 = {"consistent": True, "fail_class": "NONE", "method": "artifact_integrity", "artifact_count": 23}
    (run1 / "determinism.json").write_text(json.dumps(det1) + "\n", encoding="utf-8")
    (run2 / "determinism.json").write_text(json.dumps(det2) + "\n", encoding="utf-8")

    # Operational drift file.
    (run1 / "verify.log").write_text("run1\n", encoding="utf-8")
    (run2 / "verify.log").write_text("run2\n", encoding="utf-8")

    inventory = {
        "projection_rules_version": "v1",
        "canonical_required": [
            {"name": "status.json", "projection": "status_semantic"},
            {"name": "determinism.json", "projection": "determinism_semantic"},
        ],
        "non_deterministic_by_design": ["*.sig", "*.bundle.json"],
        "unstable_collection_boundary": ["determinism_cluster_drift.json"],
    }

    monkeypatch.setattr(ph, "_load_canonical_inventory", lambda path=ph.CANONICAL_INVENTORY_PATH: inventory)

    drift_class, details = ph.compare_with_canonical_inventory(
        run1.parent,
        run2.parent,
        emit_first_drift=False,
    )

    assert drift_class == "operational_artifact_drift"
    assert details["artifact"] == "verify.log"


def test_status_projection_ignores_completion_record_identity() -> None:
    raw = json.dumps(
        {
            "final": "PASS",
            "proof_result": "PASS",
            "fail_class": "NONE",
            "read_only_guarantees": "PASS",
            "active_guarantees": "PASS",
            "admission_rejection": "PASS",
            "injected_images_locked": "PASS",
            "ephemeral_containers_blocked": "PASS",
            "exit_semantics_consistent": "PASS",
            "not_evaluated_guarantees": [],
            "completion_record": {
                "identity": {
                    "operation_id": "proof",
                    "producer": "scripts/prove_system.sh",
                    "request_id": None,
                    "cluster_id": "cluster-123",
                    "kubectl_context": "kind-threadforge",
                },
                "outcome": {
                    "status": "PASS",
                    "proof_result": "PASS",
                    "fail_class": "NONE",
                    "strict_mode": "true",
                    "advisory_count": 0,
                },
                "evidence": {
                    "signed": True,
                    "verified": True,
                    "artifacts": {},
                    "signature_files": [],
                    "reasons": [],
                },
                "guarantees": {},
                "artifacts": {},
            },
        }
    ).encode("utf-8")

    projected = ph._project_artifact(raw, "status_semantic")

    assert "completion_record" not in projected
    assert projected["final"] == "PASS"
    assert projected["proof_result"] == "PASS"
    assert projected["fail_class"] == "NONE"
