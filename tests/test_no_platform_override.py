import pytest
from pathlib import Path


pytestmark = pytest.mark.core


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_no_platform_override_in_workflows():
    for path in (REPO_ROOT / ".github/workflows").rglob("*.yml"):
        text = path.read_text()
        assert "DOCKER_DEFAULT_PLATFORM" not in text or "linux/arm64" in text
