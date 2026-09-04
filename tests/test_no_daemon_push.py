import pytest
from pathlib import Path


pytestmark = pytest.mark.core


FORBIDDEN = "docker" + " push"
REPO_ROOT = Path(__file__).resolve().parents[1]


def test_no_daemon_push():
    for path in REPO_ROOT.rglob("*"):
        if path.is_file():
            try:
                text = path.read_text(errors="ignore")
            except PermissionError:
                continue
            if path == Path(__file__).resolve():
                continue
            if "\x00" in text:
                continue
            assert FORBIDDEN not in text, f"daemon push forbidden in {path}"
