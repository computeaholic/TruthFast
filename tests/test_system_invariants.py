import pytest
from pathlib import Path


pytestmark = pytest.mark.core


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text()


def test_makefile_exposes_lock_validation_targets() -> None:
    text = _read("Makefile")
    assert "builder-setup:" in text
    assert "lock-validate:" in text
    assert 'echo "[LOCK] Running core tests"' in text
    assert 'echo "[LOCK] Running proof"' in text
    assert 'echo "[LOCK] Running proof determinism"' in text
    assert 'echo "[LOCK] Running active validation"' in text
    assert 'echo "[LOCK] PASS"' in text
    assert '"$$PYTHON_BIN" -m pytest -m core' in text
    assert "$(MAKE) proof;" in text
    assert "$(MAKE) proof-determinism;" in text
    assert "$(MAKE) prove-active;" in text


def test_makefile_exposes_explicit_active_validation_markers() -> None:
    text = _read("Makefile")
    assert "prove-active:" in text
    assert 'echo "[ACTIVE] Starting active validation"' in text
    assert 'echo "[ACTIVE] FAIL"' in text
    assert 'echo "[ACTIVE] PASS"' in text
    assert "scripts/proof/force_spire_rotation.sh" in text
    assert "scripts/verify/verify_cert_rotation_continuity.sh" in text
    assert "scripts/proof/test_admission_denials.sh" in text


def test_bootstrap_fails_fast_on_missing_required_registry_images() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert 'bash "$REPO_ROOT/scripts/verify/verify_required_registry_images.sh"' in text


def test_registry_audit_tracks_required_registry_images() -> None:
    text = _read("scripts/verify/registry_audit.sh")
    assert "REQUIRED_REGISTRY_IMAGES_PATH=" in text
    assert "required_image_status =" in text
    assert "required image missing from registry" in text


def test_required_registry_image_refs_are_internal_and_digest_pinned() -> None:
    for relative_path in (
        "scripts/verify/allowed_system_images.txt",
        "scripts/verify/required_registry_images.txt",
    ):
        for line in _read(relative_path).splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            assert stripped.startswith("registry.threadforge.local:30500/")
            assert "@sha256:" in stripped


def test_cluster_reset_does_not_background_image_preloading() -> None:
    text = _read("scripts/ci/reset_ci_cluster.sh")
    assert "preload_images &" not in text
    assert "PRELOAD_PID" not in text
    assert "wait ${PRELOAD_PID}" not in text
