from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from scripts.proof.proof_hardening import compare_cluster_snapshots


pytestmark = pytest.mark.core


def _write_snapshot(path: Path, resources: list[dict]) -> None:
    path.write_text(json.dumps({"resources": resources}, indent=2) + "\n", encoding="utf-8")


def _resource(kind: str, name: str, namespace: str = "", **payload: Any) -> dict[str, Any]:
    resource: dict[str, Any] = {
        "apiVersion": "v1",
        "kind": kind,
        "metadata": {"name": name},
    }
    if namespace:
        resource["metadata"]["namespace"] = namespace
    resource.update(payload)
    return resource


def test_expected_pod_name_churn_does_not_fail_determinism(tmp_path: Path) -> None:
    before = tmp_path / "before.json"
    after = tmp_path / "after.json"
    _write_snapshot(before, [_resource("Pod", "test-client-a", "threadforge-test")])
    _write_snapshot(after, [_resource("Pod", "test-client-b", "threadforge-test")])

    report = compare_cluster_snapshots(before, after)

    assert report["status"] == "PASS"
    assert report["authoritative_drift_detected"] is False
    assert report["summary"]["expected_runtime_churn"] >= 1


def test_forgesec_transient_resources_do_not_fail_determinism(tmp_path: Path) -> None:
    before = tmp_path / "before.json"
    after = tmp_path / "after.json"
    _write_snapshot(before, [_resource("Job", "forgesec-identity-abc", "forgesec")])
    _write_snapshot(after, [])

    report = compare_cluster_snapshots(before, after)

    assert report["status"] == "PASS"
    assert report["summary"]["expected_forgesec_transient"] >= 1


def test_image_digest_drift_fails_determinism(tmp_path: Path) -> None:
    before = tmp_path / "before.json"
    after = tmp_path / "after.json"
    _write_snapshot(
        before,
        [
            _resource(
                "Deployment",
                "spire-csr",
                "istio-system",
                spec={
                    "template": {
                        "spec": {
                            "containers": [
                                {"name": "spire-csr", "image": "registry.threadforge.local:30500/spire-csr@sha256:1111"}
                            ]
                        }
                    }
                },
            )
        ],
    )
    _write_snapshot(
        after,
        [
            _resource(
                "Deployment",
                "spire-csr",
                "istio-system",
                spec={
                    "template": {
                        "spec": {
                            "containers": [
                                {"name": "spire-csr", "image": "registry.threadforge.local:30500/spire-csr@sha256:2222"}
                            ]
                        }
                    }
                },
            )
        ],
    )

    report = compare_cluster_snapshots(before, after)

    assert report["status"] == "FAIL"
    assert report["authoritative_drift_detected"] is True
    assert any(entry["field_path"] == "spec.template.spec.containers[0].image" for entry in report["drift"])


def test_policy_state_drift_fails_determinism(tmp_path: Path) -> None:
    before = tmp_path / "before.json"
    after = tmp_path / "after.json"
    _write_snapshot(
        before,
        [_resource("PeerAuthentication", "default", "threadforge-test", spec={"mtls": {"mode": "STRICT"}})],
    )
    _write_snapshot(
        after,
        [_resource("PeerAuthentication", "default", "threadforge-test", spec={"mtls": {"mode": "PERMISSIVE"}})],
    )

    report = compare_cluster_snapshots(before, after)

    assert report["status"] == "FAIL"
    assert any(
        entry["field_path"] == "spec.mtls.mode" and entry["classification"] == "authoritative"
        for entry in report["drift"]
    )


def test_trust_root_drift_fails_determinism(tmp_path: Path) -> None:
    before = tmp_path / "before.json"
    after = tmp_path / "after.json"
    _write_snapshot(
        before,
        [_resource("ConfigMap", "spire-ca-root-cert", "spire-system", data={"root-cert.pem": "root-a"})],
    )
    _write_snapshot(
        after,
        [_resource("ConfigMap", "spire-ca-root-cert", "spire-system", data={"root-cert.pem": "root-b"})],
    )

    report = compare_cluster_snapshots(before, after)

    assert report["status"] == "FAIL"
    assert any(
        entry["field_path"] == "data.root-cert.pem" and entry["classification"] == "authoritative"
        for entry in report["drift"]
    )
