from __future__ import annotations

from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_successor_validator_is_observe_only() -> None:
    text = (REPO_ROOT / "scripts" / "trust" / "spire_native_successor_validator.py").read_text(encoding="utf-8")
    assert "ec.generate_private_key" not in text
    assert "x509.random_serial_number" not in text
    assert "os.replace" not in text
    assert "bundle set" not in text
    assert '"mutation_performed": False' in text


def test_successor_verifier_uses_lifecycle_guard_truth() -> None:
    text = (REPO_ROOT / "scripts" / "verify" / "verify_successor_root_provisioning.sh").read_text(encoding="utf-8")
    assert "verify_root_lifecycle_continuity.sh" in text
    assert "root_lifecycle_status.json" in text
    assert "spire_native_continuity_predicates" in text
    assert "spire_native_successor_validator.py" not in text
    assert "trust_root_successor_provisioner.py" not in text
