import pytest
from pathlib import Path


pytestmark = pytest.mark.core


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text()


def test_runtime_paths_do_not_reference_tagged_kind_or_forgesec_images() -> None:
    runtime_files = (
        ".github/workflows/repository-quality.yml",
        ".github/workflows/governance.yml",
        ".github/workflows/publication.yml",
        "platform/build/kind/kind-config.yaml",
        "platform/deploy/forgesec/identity-job.yaml",
        "platform/deploy/forgesec/surface-job.yaml",
    )
    for relative_path in runtime_files:
        text = _read(relative_path)
        assert "registry.threadforge.local:30500/kindest-node:v1.30.2-registry-trust" not in text
        assert "registry.threadforge.local:30500/forgesec:v2" not in text


def test_forgesec_runtime_manifests_match_canonical_inventory() -> None:
    inventory_text = _read("platform/config/canonical_image_inventory.json")
    expected = (
        "registry.threadforge.local:30500/forgesec@sha256:"
        "b20b0a077cb612d94c0dd07819d58637b0d7573f01664df9ed477b556e455a50"
    )
    assert expected in inventory_text

    runtime_files = (
        "platform/deploy/forgesec/identity-job.yaml",
        "platform/deploy/forgesec/surface-job.yaml",
        "platform/deploy/infra/observability/forgesec-continuity-check-cronjob.yaml",
    )
    for relative_path in runtime_files:
        assert expected in _read(relative_path)
