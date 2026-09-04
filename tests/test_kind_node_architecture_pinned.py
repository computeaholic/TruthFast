import pytest
from pathlib import Path


pytestmark = pytest.mark.core


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_kind_node_release_resolves_arm64_child_digest() -> None:
    text = (REPO_ROOT / "scripts/make/images.mk").read_text()
    assert "KIND_NODE_PLATFORM := linux/arm64" in text
    assert (
        "docker buildx build --builder threadforge-builder --platform linux/arm64 -t $(KIND_NODE_TAGGED_IMAGE) --push"
        in text
    )
    assert 'docker buildx imagetools inspect "$(KIND_NODE_TAGGED_IMAGE)"' in text
    assert "Platform:[[:space:]]+linux\\/arm64" in text
    assert 'cosign sign --yes --key "$(COSIGN_KEY_PATH)" "$$kind_node_ref"' in text
    assert "--allow-insecure-registry" not in text
    assert "linux/amd64,linux/arm64" not in text


def test_forgesec_canonical_build_is_arm64_only() -> None:
    text = (REPO_ROOT / "scripts/make/forgesec.mk").read_text()
    assert "docker buildx build --builder threadforge-builder --platform linux/arm64 --pull --push" in text
    assert 'docker buildx imagetools inspect "$${IMAGE_TAG}"' in text
    assert "Platform:[[:space:]]+linux\\/arm64" in text
    assert "linux/amd64" not in text


def test_core_image_build_targets_are_arm64_only() -> None:
    text = (REPO_ROOT / "scripts/make/core.mk").read_text()
    assert "--platform linux/arm64" in text
    assert "linux/amd64" not in text
