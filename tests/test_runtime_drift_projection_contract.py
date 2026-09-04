from __future__ import annotations

from pathlib import Path

from scripts.debug.runtime_drift_policy import (
    approved_runtime_projection,
    classify_runtime_projection,
)


PREFIX = "registry.threadforge.local:30500/"
PARENT = f"{PREFIX}agents-lab/agent@sha256:" + "a" * 64
CHILD = f"{PREFIX}agents-lab/agent@sha256:" + "b" * 64
EXTERNAL_CHILD = "docker.io/library/agent@sha256:" + "b" * 64
FINGERPRINT = ("sha256:config", ("sha256:layer",))
OTHER_FINGERPRINT = ("sha256:other", ("sha256:layer",))


def test_valid_child_alias_requires_signed_parent() -> None:
    assert classify_runtime_projection(PARENT, CHILD, [FINGERPRINT], [FINGERPRINT], PREFIX) == "manifest_projection"
    assert approved_runtime_projection(PARENT, CHILD, [FINGERPRINT], [FINGERPRINT], [PARENT], PREFIX)


def test_unrelated_child_is_rejected() -> None:
    assert classify_runtime_projection(PARENT, CHILD, [FINGERPRINT], [OTHER_FINGERPRINT], PREFIX) == "unexplained_runtime_digest"


def test_unsigned_parent_is_rejected() -> None:
    assert not approved_runtime_projection(PARENT, CHILD, [FINGERPRINT], [FINGERPRINT], [], PREFIX)


def test_external_child_is_rejected() -> None:
    assert classify_runtime_projection(PARENT, EXTERNAL_CHILD, [FINGERPRINT], [FINGERPRINT], PREFIX) == "external_runtime_digest"
    assert not approved_runtime_projection(PARENT, EXTERNAL_CHILD, [FINGERPRINT], [FINGERPRINT], [PARENT], PREFIX)


def test_stale_alias_is_rejected() -> None:
    assert classify_runtime_projection(PARENT, CHILD, [FINGERPRINT], [OTHER_FINGERPRINT], PREFIX) == "unexplained_runtime_digest"


def test_missing_runtime_projection_requires_reconciliation() -> None:
    assert classify_runtime_projection(PARENT, "", [FINGERPRINT], [FINGERPRINT], PREFIX) == "missing_digest"
    assert not approved_runtime_projection(PARENT, "", [FINGERPRINT], [FINGERPRINT], [PARENT], PREFIX)


def test_supported_lifecycle_runs_projection_before_signature_verification() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    proof = (repo_root / "scripts/prove_system.sh").read_text(encoding="utf-8")
    deploy = (repo_root / "scripts/install/deploy_lab.sh").read_text(encoding="utf-8")
    reconcile = (repo_root / "scripts/debug/reconcile_runtime_drift.sh").read_text(encoding="utf-8")
    assert "CLASSIFY_DRIFT_PROJECTION_ONLY=true" in reconcile
    assert deploy.index("reconcile_runtime_drift.sh") < deploy.index("Apply policies")
    assert proof.rindex("reconcile_runtime_drift.sh") < proof.rindex("scripts/verify/verify_signatures.sh")
