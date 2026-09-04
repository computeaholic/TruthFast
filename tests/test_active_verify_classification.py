from pathlib import Path
import re

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
PROVE_SYSTEM = REPO_ROOT / "scripts" / "prove_system.sh"
MAKEFILE = REPO_ROOT / "Makefile"
MUTATION_RE = re.compile(
    r"(?:^|[^A-Za-z0-9_])(?:kubectl|run_real_kubectl)\s+(?:apply|create|delete|patch|replace|run|debug)\b",
    re.MULTILINE,
)


def _verify_phase_scripts() -> list[Path]:
    text = PROVE_SYSTEM.read_text()
    matches = re.findall(r'scripts/(?:verify|proof)/[^"\s]+\.sh', text)
    seen = []
    for rel_path in matches:
        path = REPO_ROOT / rel_path
        if path not in seen:
            seen.append(path)
    return seen


def _verify_type(path: Path) -> str | None:
    match = re.search(r"^export VERIFY_TYPE=(.+)$", path.read_text(), re.MULTILINE)
    if not match:
        return None
    return match.group(1).strip().strip('"')


pytestmark = pytest.mark.unit


def test_proof_mode_enables_active_checks_for_canonical_proof() -> None:
    text = PROVE_SYSTEM.read_text()
    assert "ACTIVE_VALIDATION not allowed in proof mode" in text


def test_proof_active_explicitly_enables_active_verifiers() -> None:
    text = MAKEFILE.read_text()
    assert "VERIFY_EXECUTION_MODE=proof-active" in text
    assert "THREADFORGE_PROOF_INCLUDE_ACTIVE_VERIFY=true" in text
    assert "VERIFY_EXECUTION_MODE=proof THREADFORGE_PROOF_INCLUDE_ACTIVE_VERIFY=true" in text


def test_proof_invoked_mutating_scripts_are_classified_active() -> None:
    offending = []
    for path in _verify_phase_scripts():
        text = path.read_text()
        if not MUTATION_RE.search(text):
            continue
        if "proof_mode_active()" in text or 'proof_mode = os.getenv("VERIFY_EXECUTION_MODE") == "proof"' in text:
            continue
        verify_type = _verify_type(path)
        if verify_type != "ACTIVE":
            offending.append((path.relative_to(REPO_ROOT).as_posix(), verify_type))

    assert offending == [], f"mutating proof-invoked scripts must export VERIFY_TYPE=ACTIVE: {offending}"
