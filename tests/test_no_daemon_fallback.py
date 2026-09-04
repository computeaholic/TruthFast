import pytest
from pathlib import Path


pytestmark = pytest.mark.core


REPO_ROOT = Path(__file__).resolve().parents[1]
SCAN_ROOTS = (
    REPO_ROOT / ".github",
    REPO_ROOT / "scripts",
    REPO_ROOT / "platform/build",
    REPO_ROOT / "platform/images",
    REPO_ROOT / "Makefile",
)
FORBIDDEN = ("docker" + " push", "docker" + " build ")


def _iter_files():
    for root in SCAN_ROOTS:
        if root.is_file():
            yield root
            continue
        for path in root.rglob("*"):
            if path.is_file() and "__pycache__" not in path.parts:
                yield path


def test_canonical_paths_do_not_use_daemon_build_or_push() -> None:
    for path in _iter_files():
        text = path.read_text(errors="ignore")
        for forbidden in FORBIDDEN:
            assert forbidden not in text, f"daemon fallback forbidden in {path.relative_to(REPO_ROOT)}"
