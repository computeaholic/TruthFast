import pytest
from pathlib import Path


pytestmark = pytest.mark.core


REPO_ROOT = Path(__file__).resolve().parents[1]
EXPECTED_KIND_NODE_REF = (
    "registry.threadforge.local:30500/kindest-node@sha256:"
    "48321fb2717f92527d9aba9a9b32055dff622f9c356ea3de2f1ffb75344f87bf"
)
CHECK_FILES = (
    "platform/build/kind/kind-config.yaml",
    "scripts/lib/ensure_cluster.sh",
    "scripts/ci/reset_ci_cluster.sh",
    "scripts/verify/allowed_system_images.txt",
)


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text()


def test_kind_node_digest_is_locked_across_canonical_paths() -> None:
    for relative_path in CHECK_FILES:
        assert EXPECTED_KIND_NODE_REF in _read(relative_path), f"kind node digest drifted in {relative_path}"


def test_legacy_kind_node_tag_is_absent_from_runtime_paths() -> None:
    for relative_path in CHECK_FILES[:-1]:
        assert "threadforge/kindest-node:v1.30.2-registry-trust" not in _read(relative_path)
