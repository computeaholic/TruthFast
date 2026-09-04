from __future__ import annotations

import re
from pathlib import Path

import pytest

pytestmark = pytest.mark.core
REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(path: str) -> str:
    return (REPO_ROOT / path).read_text(encoding="utf-8")


def _target_body(text: str, target: str) -> str:
    match = re.search(
        rf"(?ms)^{re.escape(target)}:[^\n]*\n(.*?)(?=^[A-Za-z0-9_.-]+:[^=]|\Z)",
        text,
    )
    return match.group(1) if match else ""


def test_kind_is_the_only_native_lifecycle_owner() -> None:
    makefile = _read("Makefile")
    assert "golden-boot:" in makefile
    assert "bootstrap: infra-bootstrap bootstrap-verify" in makefile
    assert "reset: cluster-reset bootstrap" in makefile
    assert "down: nuke" in makefile

    for target in ("bootstrap", "nuke", "rebuild", "verify-golden", "golden-boot"):
        body = _target_body(makefile, target)
        assert "k3-install" not in body
        assert "k3-wipe" not in body
        assert "kubeconfig-sync" not in body
        assert "vm-preflight" not in body


def test_golden_boot_is_single_owner_and_automates_full_validation() -> None:
    script = _read("scripts/operator/golden_boot.sh")
    assert 'RUNTIME_OWNER=kind' in script
    assert "make native-host-contract-verify" in script
    assert "python3 scripts/verify/namespace_contract.py" in script
    assert "make validate-all-full-reset" in script
    assert "git status --porcelain" in script
    assert "SOURCE_SHA=$source_sha" in script
    assert "k3-" not in script
    assert "ssh " not in script


def test_full_reset_semantics_are_kind_reset_bootstrap_and_validation() -> None:
    makefile = _read("Makefile")
    validate_script = _read("scripts/verify/validate_all.sh")
    full_reset = _target_body(makefile, "validate-all-full-reset")
    assert "THREADFORGE_HOST_TRUST_MUTATION=allowed" in full_reset
    assert "make cluster-reset" in validate_script
    assert "make infra-bootstrap BOOTSTRAP_MODE=strict" in validate_script
    assert 'log "FINAL: ${FINAL}"' in validate_script


def test_registry_and_trust_are_explicit_persistent_host_contract() -> None:
    verifier = _read("scripts/infra/verify_native_host_contract.sh")
    assert "threadforge-registry" in verifier
    assert "certs/threadforge-ingress-ca.crt" in verifier
    assert "skopeo inspect" in verifier
    assert "host_trust_prime.sh" in verifier


def test_k3s_is_retained_only_as_non_native_operator_utility() -> None:
    k3 = _read("scripts/make/k3.mk")
    assert "non-native operator utilities" in k3
    assert "intentionally excluded" in k3
    assert "k3-install: vm-preflight" in k3
    assert "k3-wipe: vm-preflight" in k3


def test_static_ci_workflows_never_invoke_native_golden_boot() -> None:
    for workflow in (REPO_ROOT / ".github/workflows").glob("*.yml"):
        text = workflow.read_text(encoding="utf-8")
        assert "make golden-boot" not in text
