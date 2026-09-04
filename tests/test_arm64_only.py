import pytest
from pathlib import Path


pytestmark = pytest.mark.core


REPO_ROOT = Path(__file__).resolve().parents[1]
CANONICAL_FILES = (
    ".github/workflows/repository-quality.yml",
    ".github/workflows/governance.yml",
    ".github/workflows/publication.yml",
    "scripts/make/images.mk",
    "scripts/make/core.mk",
    "scripts/make/forgesec.mk",
    "scripts/build/setup_builder.sh",
)


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text()


def test_canonical_build_paths_are_arm64_only() -> None:
    for relative_path in CANONICAL_FILES:
        text = _read(relative_path)
        assert "linux/amd64" not in text, f"canonical path drifted to amd64 in {relative_path}"


def test_arm64_is_not_overridden_in_ci_workflows() -> None:
    for workflow in (
        ".github/workflows/repository-quality.yml",
        ".github/workflows/governance.yml",
        ".github/workflows/publication.yml",
    ):
        assert "DOCKER_DEFAULT_PLATFORM" not in _read(workflow)
    assert "export DOCKER_DEFAULT_PLATFORM=linux/arm64" in _read("scripts/make/images.mk")
    assert "KIND_NODE_PLATFORM := linux/arm64" in _read("scripts/make/images.mk")
    assert "--platform linux/arm64" in _read("scripts/build/setup_builder.sh")
