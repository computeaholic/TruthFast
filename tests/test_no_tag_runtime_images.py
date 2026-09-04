import re
from pathlib import Path

import pytest
import yaml


pytestmark = pytest.mark.core


REPO_ROOT = Path(__file__).resolve().parents[1]
RUNTIME_FILES = (
    "platform/build/kind/kind-config.yaml",
    "scripts/lib/ensure_cluster.sh",
    "scripts/ci/reset_ci_cluster.sh",
)
IMAGE_REF_RE = re.compile(r"registry\.threadforge\.local:30500/[A-Za-z0-9._/@:-]+")


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text()


def test_canonical_runtime_refs_are_digest_pinned() -> None:
    for relative_path in RUNTIME_FILES:
        text = _read(relative_path)
        refs = IMAGE_REF_RE.findall(text)
        assert refs, f"expected runtime refs in {relative_path}"
        for image_ref in refs:
            assert "@sha256:" in image_ref, f"runtime ref must be digest pinned in {relative_path}: {image_ref}"


def test_ci_workflows_do_not_embed_runtime_image_refs() -> None:
    for workflow in (
        ".github/workflows/repository-quality.yml",
        ".github/workflows/governance.yml",
        ".github/workflows/publication.yml",
    ):
        assert "registry.threadforge.local:30500/" not in _read(workflow)


def test_registry_completeness_does_not_treat_pod_status_image_as_authoritative() -> None:
    text = _read("scripts/verify/verify_registry_completeness.sh")
    assert 'status_field in ("containerStatuses", "initContainerStatuses", "ephemeralContainerStatuses")' not in text
    assert 'status.image' not in text


def test_registry_completeness_runtime_refs_remain_digest_pinned() -> None:
    wrapper_text = _read("scripts/verify/verify_registry_completeness.sh")
    helper_text = _read("scripts/verify/registry_completeness.py")
    signer_text = _read("scripts/supply_chain/sign_images.sh")
    makefile_text = _read("Makefile")
    assert "registry.threadforge.local:30500/" in wrapper_text
    assert "registry_completeness.py" in wrapper_text
    assert "REGISTRY_COMPLETENESS_MAX_CONCURRENCY" in wrapper_text
    assert "PROOF_LOG_DIR" in wrapper_text
    assert "registry_completeness_inventory.json" in helper_text
    assert "sha256:[0-9a-fA-F]{64}" in helper_text
    assert "ThreadPoolExecutor" in helper_text
    assert "[registry-completeness] PROGRESS" in helper_text
    assert "COLLECT_SCOPE=\"${COLLECT_SCOPE:-managed}\"" in signer_text
    assert '--scope "$COLLECT_SCOPE"' in signer_text
    assert "wait_for_signature_convergence" in signer_text
    assert "default scope is managed" in signer_text.lower()
    assert "COLLECT_SCOPE=cluster bash scripts/supply_chain/sign_images.sh" in makefile_text


def test_allowed_runtime_images_match_current_system_allowlist() -> None:
    data = yaml.safe_load(_read("platform/deploy/infra/system/allowed-runtime-images.yaml"))
    images = [entry["image"] for entry in data["images"]]
    assert images == [
        "registry.threadforge.local:30500/curlimages-curl@sha256:56efe57deecfd4145a36b24f1cfd676f8cbda808b5ce56d0f644ca0db6b1c0de",
        "registry.threadforge.local:30500/hashicorp/http-echo@sha256:3f5c9a5a28daf63a712bbf45f2fa0741be9cd34339ba598a5c13af02959f108d",
        "registry.threadforge.local:30500/istio/pilot@sha256:32515653577393f5e6375ccc1350a0cf0aabdd733f8fe9265bb51003a10be26f",
        "registry.threadforge.local:30500/kyverno/background-controller@sha256:148e3f0f5f0c84f3cf1428f5460b680c15d1e190f3e6182e2e02ff177071a5be",
        "registry.threadforge.local:30500/kyverno/cleanup-controller@sha256:72be48bd94266ae87f9ad6567d8f8a6c1ef6ca173adb8c8bcceab7c1c9b9a242",
        "registry.threadforge.local:30500/kyverno/kyverno@sha256:2e1af149ebf318b67233c519225b403ca0500c657b347553c74627ccb6f369f7",
        "registry.threadforge.local:30500/kyverno/kyvernopre@sha256:94e787023a71c1a2850388a9fe190b45156684fe7f20f59132edfe6b57e17d31",
        "registry.threadforge.local:30500/kyverno/reports-controller@sha256:aa878cc71678d45d63775a0014244b5d238dfcfcd4e79ad8be3158d08e7b71b2",
    ]


def test_kyverno_values_match_current_canonical_digests() -> None:
    text = _read("platform/deploy/infra/kyverno/values.yaml")
    assert "registry: registry.threadforge.local:30500" in text
    assert "repository: kyverno/background-controller@sha256" in text
    assert "tag: 148e3f0f5f0c84f3cf1428f5460b680c15d1e190f3e6182e2e02ff177071a5be" in text
    assert "tag: 184387a6fb4e7dda1c3f6057fe9e1d48c0f0e7e300118ad88505574ebd6486dd" not in text


def test_envoy_runtime_refs_match_current_canonical_digest() -> None:
    for relative_path in (
        "platform/deploy/infra/minio/minio-envoy.yaml",
        "platform/deploy/infra/observability/monitoring/blackbox/deployment.yaml",
        "platform/deploy/debug/envoy-sds-test.yaml",
    ):
        text = _read(relative_path)
        assert (
            "registry.threadforge.local:30500/mirror/docker.io/envoyproxy/envoy@sha256:deb1d3a3cfc53d9306465426b4cc2b9443bea4b6100f2a0caf224ce3be23c0ad"
            in text
        )
        assert "3a1dcd02398649de19b46458977f9289645890c0f2283a7d185ae0ed1dcacb7e" not in text


def test_python_runtime_refs_match_current_canonical_digest() -> None:
    for relative_path in (
        "platform/deploy/infra/observability/observability-check-cronjob.yaml",
        "platform/deploy/infra/istio/runtime-images.yaml",
    ):
        text = _read(relative_path)
        assert (
            "registry.threadforge.local:30500/mirror/docker.io/library/python@sha256:36ae442f0f0d4bc85c5122666b64222a9a8584e2f61a3b286e0d72cc30c29632"
            in text
        )
        assert "c80b8a915802074a84d8e08c1a5af1d94e29e5b87a6177f35c9cd1bcba978c92" not in text


def test_dex_runtime_refs_match_current_canonical_digest() -> None:
    for relative_path in (
        "platform/deploy/base/argocd/install.yaml",
        "platform/deploy/gitops/argocd/install.yaml",
    ):
        text = _read(relative_path)
        assert (
            "registry.threadforge.local:30500/mirror/ghcr.io/dexidp/dex@sha256:f579d00721b0d842328c43a562f50343c54b0048ef2d58d6b54e750c21fc7938"
            in text
        )
        assert "97f7ced3a0d3d65108d46f7d64cb487f7433d8166402ab5ff0fffb618625ecde" not in text


def test_spire_server_runtime_refs_match_current_canonical_digest() -> None:
    for relative_path in (
        "platform/deploy/infra/minio/spire-register-envoy-job.yaml",
        "platform/deploy/infra/minio/spire-register-minio-envoy-direct.yaml",
        "platform/deploy/infra/minio/spire-register-minio-envoy-fix.yaml",
        "platform/deploy/infra/minio/spire-register-minio-job.yaml",
        "platform/deploy/infra/observability/monitoring/spire-register-blackbox-job.yaml",
    ):
        text = _read(relative_path)
        assert (
            "registry.threadforge.local:30500/spiffe/spire-server@sha256:817a87c37a6b77ff74c95908160ee0555daac8d8269e2fd7ad2b6e41b86164d8"
            in text
        )
        assert (
            "mirror/ghcr.io/spiffe/spire-server@sha256:817a87c37a6b77ff74c95908160ee0555daac8d8269e2fd7ad2b6e41b86164d8"
            not in text
        )


def test_argocd_runtime_refs_match_current_canonical_digest() -> None:
    for relative_path in (
        "platform/deploy/base/argocd/install.yaml",
        "platform/deploy/gitops/argocd/install.yaml",
    ):
        text = _read(relative_path)
        assert (
            "registry.threadforge.local:30500/mirror/quay.io/argoproj/argocd@sha256:5f1de1b4d959868c1e006e08d46361c8f019d9730e74bc1feeab8c7b413f1187"
            in text
        )
        assert "10fc34124a09fd854b5635921e8ad484743dad08d93652a271b2cc2609d4c506" not in text


def test_runtime_ledger_values_match_current_canonical_digests() -> None:
    text = _read("platform/deploy/infra/runtime/values.yaml")
    assert "sha256:e0de2c09a306446d1a702a2f8deafd5dca9d573ea01f32d9c938394641af9dda" in text
    assert "sha256:b79ccd3b6a241904a422b4d33bfd55762c8e9f4d6b10604c5c1221fd48a85100" in text
    assert "sha256:4e86925b447ac974b8cd6a2190cc4e2127c0b6306d150e2b1278e530d8371fe4" in text
    assert "393cadd486022816e22e299ed7d3a570de235caac86e38b46ff36e256bc9489f" not in text


def test_threadforge_operator_runtime_ref_matches_current_canonical_digest() -> None:
    text = _read("platform/deploy/runtime/kubernetes/threadforge-operator-deployment.yaml")
    assert (
        "registry.threadforge.local:30500/threadforge-operator@sha256:315ddcc7449efdcc4f78c2de5423f285c37e71327394b77ee98ce84a8c4c5806"
        in text
    )
    assert "fc33152f8732d3081bfe79b2a1689f18e644cacf9cd2b46fd9f0054c341622b7" not in text
