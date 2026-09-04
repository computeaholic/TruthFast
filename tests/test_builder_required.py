import pytest
from pathlib import Path


pytestmark = pytest.mark.core


REPO_ROOT = Path(__file__).resolve().parents[1]
CANONICAL_BUILD_FILES = (
    "scripts/make/images.mk",
    "scripts/make/core.mk",
    "scripts/make/forgesec.mk",
)


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text()


def test_builder_setup_script_is_present_and_reproducible() -> None:
    text = _read("scripts/build/setup_builder.sh")
    expected_create = (
        'docker buildx create --name "$BUILDER_NAME" --driver docker-container '
        '--driver-opt network=host --config "$tmp_dir/buildkitd.toml" --use'
    )
    assert expected_create in text
    assert 'docker buildx inspect --bootstrap "$BUILDER_NAME"' in text
    assert "registry.threadforge.local:30500/buildkit-smoke:builder-test" in text
    assert 'smoke_cert_dir="$(mktemp -d)"' in text
    assert 'cp "$REGISTRY_CA_CERT_PATH" "$smoke_cert_dir/ca.crt"' in text
    assert '--cert-dir "$smoke_cert_dir"' in text


def test_registry_hardening_reconciles_buildkit_after_registry_recreation() -> None:
    text = _read("scripts/infra/harden_local_registry.sh")

    assert 'scripts/build/setup_builder.sh' in text
    assert 'THREADFORGE_SKIP_BUILDER_SETUP' in text
    assert 'docker buildx' not in text


def test_canonical_buildx_paths_require_threadforge_builder() -> None:
    for relative_path in CANONICAL_BUILD_FILES:
        text = _read(relative_path)
        buildx_invocations = text.count("docker buildx build")
        assert buildx_invocations > 0, f"expected canonical buildx usage in {relative_path}"
        assert (
            text.count("--builder threadforge-builder") >= buildx_invocations
        ), f"missing canonical builder usage in {relative_path}"
