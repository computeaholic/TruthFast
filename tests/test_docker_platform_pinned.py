import pytest
from pathlib import Path


pytestmark = pytest.mark.core


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_docker_platform_pinned():
    text = (REPO_ROOT / "scripts/make/images.mk").read_text()
    assert "export DOCKER_DEFAULT_PLATFORM=linux/arm64" in text
