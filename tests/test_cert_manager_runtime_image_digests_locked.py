from pathlib import Path

import pytest


pytestmark = pytest.mark.core


REPO_ROOT = Path(__file__).resolve().parents[1]
EXPECTED_CERT_MANAGER_REFS = {
    "registry.threadforge.local:30500/cert-manager/controller@sha256:6bf0fd34e1d5b58e31bfdc640d5d284e528685b19f20df6c0fb6f13867603bba",
    "registry.threadforge.local:30500/cert-manager/cainjector@sha256:6381b508a274d56f0ed3ac6af76faf12e3e5a2e0028d33a13039e364c45c93ff",
    "registry.threadforge.local:30500/cert-manager/webhook@sha256:7f16d397b8b48c5133d9f2859fb2dea30f0f297eb04c517bbfc06f5d207b3cf0",
    "registry.threadforge.local:30500/cert-manager/startupapicheck@sha256:d313d9b8a846c163e52eebe68fd5e7da2457fddda2f144848de17b6fcd6e14f4",
}
EXPECTED_BOOTSTRAP_DIGESTS = {
    "sha256:6bf0fd34e1d5b58e31bfdc640d5d284e528685b19f20df6c0fb6f13867603bba",
    "sha256:6381b508a274d56f0ed3ac6af76faf12e3e5a2e0028d33a13039e364c45c93ff",
    "sha256:7f16d397b8b48c5133d9f2859fb2dea30f0f297eb04c517bbfc06f5d207b3cf0",
    "sha256:d313d9b8a846c163e52eebe68fd5e7da2457fddda2f144848de17b6fcd6e14f4",
}
CHECK_FILES = (
    "platform/config/canonical_image_inventory.json",
    "platform/deploy/infra/cert-manager/runtime-images.yaml",
    "scripts/verify/verify_required_registry_images.sh",
)


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def test_cert_manager_runtime_image_digests_are_consistent() -> None:
    for relative_path in CHECK_FILES:
        text = _read(relative_path)
        for ref in EXPECTED_CERT_MANAGER_REFS:
            assert ref in text, f"cert-manager runtime image drifted in {relative_path}: {ref}"

    allowed_system_images = _read("scripts/verify/allowed_system_images.txt")
    assert EXPECTED_CERT_MANAGER_REFS and (
        "registry.threadforge.local:30500/cert-manager/webhook@sha256:7f16d397b8b48c5133d9f2859fb2dea30f0f297eb04c517bbfc06f5d207b3cf0"
        in allowed_system_images
    )


def test_cert_manager_bootstrap_uses_the_same_cert_manager_digests() -> None:
    bootstrap_text = _read("scripts/infra/bootstrap.sh")
    assert "startupapicheck.image.repository=${cert_manager_registry_hostport}/cert-manager/startupapicheck" in bootstrap_text
    for digest in EXPECTED_BOOTSTRAP_DIGESTS:
        assert digest in bootstrap_text, f"cert-manager bootstrap digest drifted: {digest}"


def test_legacy_cert_manager_runtime_image_digests_are_absent() -> None:
    legacy_refs = {
        "registry.threadforge.local:30500/cert-manager/controller@sha256:0b4857153cf08f13261ee562c868138ef92fad11b59e056473f0b94591e2f4fb",
        "registry.threadforge.local:30500/cert-manager/cainjector@sha256:41eebecf1ceec4ac1252f5c1e221b93d5c7cfd4d1cdadcd34452faf01570e178",
        "registry.threadforge.local:30500/cert-manager/webhook@sha256:79d5c587158b98bb97ce60dc9501fcfebb7c15077be6c83cfbdbeac3783be629",
        "registry.threadforge.local:30500/cert-manager/startupapicheck@sha256:9654902526ab7d8ce2318175828b7d60407c4f03a58335d7a860abeb26ce09c8",
    }
    for relative_path in CHECK_FILES + ("scripts/infra/bootstrap.sh",):
        text = _read(relative_path)
        for ref in legacy_refs:
            assert ref not in text, f"legacy cert-manager digest remains in {relative_path}: {ref}"
