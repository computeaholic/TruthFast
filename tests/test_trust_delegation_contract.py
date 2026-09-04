from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def test_trust_docs_explicitly_delegate_successor_publication_to_spire() -> None:
    trust_model = _read("docs/CANONICAL/TRUST_MODEL.md")
    start_here = _read("docs/START_HERE.md")
    observability = _read("docs/operations/OBSERVABILITY.md")

    assert "SPIRE is also the explicit producer of successor trust roots." in trust_model
    assert "ThreadForge observes and validates that state; it does not synthesize successor roots inside the proof path." in trust_model
    assert "Successor trust-root publication is SPIRE-owned and ThreadForge only witnesses it." in start_here
    assert "SPIRE-prepared successor" in observability


def test_trust_lifecycle_scripts_remain_observe_only() -> None:
    collector = _read("scripts/trust/collect_spire_lifecycle_state.py")
    verifier = _read("scripts/verify/verify_successor_root_provisioning.sh")
    validator = _read("scripts/trust/spire_native_successor_validator.py")

    assert "observe-only bridge" in collector
    assert "does not generate roots, write" in validator
    assert "mutation_performed\": False" in validator
    assert "SPIRE owns generation" in verifier
