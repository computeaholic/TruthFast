from __future__ import annotations

from pathlib import Path

import pytest
import yaml

pytestmark = pytest.mark.unit

REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST_GLOBS = ("platform/**/*.yaml", "platform/**/*.yml")
TARGET_KINDS = {"Pod", "Deployment", "StatefulSet", "Job"}
SKIP_SUFFIXES = (".values.yaml", ".values.yml", ".disabled")


def _iter_yaml_paths() -> list[Path]:
    seen: set[Path] = set()
    paths: list[Path] = []
    for pattern in MANIFEST_GLOBS:
        for path in REPO_ROOT.glob(pattern):
            if not path.is_file() or path in seen:
                continue
            if any(str(path).endswith(suffix) for suffix in SKIP_SUFFIXES):
                continue
            seen.add(path)
            paths.append(path)
    return sorted(paths)


def _iter_documents(path: Path):
    try:
        documents = list(yaml.safe_load_all(path.read_text(encoding="utf-8")))
    except yaml.YAMLError:
        return []

    flattened: list[dict] = []
    for document in documents:
        if not isinstance(document, dict):
            continue
        if document.get("kind") == "List" and isinstance(document.get("items"), list):
            flattened.extend(item for item in document["items"] if isinstance(item, dict))
            continue
        flattened.append(document)
    return flattened


def _container_has_full_resources(container: dict) -> bool:
    resources = container.get("resources")
    if not isinstance(resources, dict):
        return False
    requests = resources.get("requests")
    limits = resources.get("limits")
    if not isinstance(requests, dict) or not isinstance(limits, dict):
        return False
    return all(requests.get(key) not in (None, "") for key in ("cpu", "memory")) and all(
        limits.get(key) not in (None, "") for key in ("cpu", "memory")
    )


def _pod_spec_for(document: dict) -> dict:
    if document.get("kind") == "Pod":
        return document.get("spec") or {}
    return ((document.get("spec") or {}).get("template") or {}).get("spec") or {}


def test_bootstrap_applies_require_resources_policy() -> None:
    bootstrap_text = (REPO_ROOT / "scripts" / "infra" / "bootstrap.sh").read_text(encoding="utf-8")
    assert "kubectl apply -f platform/policies/require-resources.yaml" in bootstrap_text
    assert "platform/deploy/infra/local-path-storage/local-path-config.yaml" in bootstrap_text
    assert "ensure_runtime_registry_credentials_secret local-path-storage" in bootstrap_text
    assert "local-path-provisioner-service-account" in bootstrap_text
    assert "patch deployment local-path-provisioner" in bootstrap_text
    assert "rollout restart deployment/local-path-provisioner" in bootstrap_text


def test_require_resources_policy_is_enforced() -> None:
    policy_text = (REPO_ROOT / "platform" / "policies" / "require-resources.yaml").read_text(encoding="utf-8")
    assert "validationFailureAction: Enforce" in policy_text
    assert "kind: ClusterPolicy" in policy_text
    assert "- Pod" in policy_text
    assert "- Deployment" in policy_text
    assert "- StatefulSet" in policy_text
    assert "- Job" in policy_text
    assert "- kube-system" in policy_text
    assert "- kube-public" in policy_text
    assert "- kube-node-lease" in policy_text
    assert "- istio-system" in policy_text
    assert "- cert-manager" in policy_text
    assert "- spire-system" in policy_text


def test_makefile_exposes_resource_contract_gates() -> None:
    makefile_text = (REPO_ROOT / "Makefile").read_text(encoding="utf-8")
    assert "k8s-lint:" in makefile_text
    assert "-m pytest -q tests/test_resource_requirements.py" in makefile_text
    assert "k8s-admission-check:" in makefile_text
    assert (
        "kubectl apply --dry-run=server -f platform/deploy/infra/monitoring/debug/curl-pod.yaml >/dev/null"
        in makefile_text
    )


def test_manifests_define_requests_and_limits_for_target_workloads() -> None:
    offenders: list[str] = []

    for path in _iter_yaml_paths():
        for document in _iter_documents(path):
            kind = document.get("kind")
            if kind not in TARGET_KINDS:
                continue

            pod_spec = _pod_spec_for(document)
            for field_name in ("containers", "initContainers"):
                containers = pod_spec.get(field_name) or []
                if not isinstance(containers, list):
                    continue
                for index, container in enumerate(containers):
                    if not isinstance(container, dict):
                        invalid_container_msg = (
                            f"{path.relative_to(REPO_ROOT)} {kind} {field_name}[{index}] "
                            "is not a valid container mapping"
                        )
                        offenders.append(invalid_container_msg)
                        continue
                    if _container_has_full_resources(container):
                        continue
                    missing_resources_msg = (
                        f"{path.relative_to(REPO_ROOT)} {kind} {field_name}[{index}] "
                        f"{container.get('name', '<unnamed>')} "
                        "missing full cpu/memory requests+limits"
                    )
                    offenders.append(missing_resources_msg)

    assert not offenders, "Manifest resource contract violations:\n" + "\n".join(sorted(offenders))


def test_local_path_helper_config_declares_resources() -> None:
    text = (REPO_ROOT / "platform" / "deploy" / "infra" / "local-path-storage" / "local-path-config.yaml").read_text(
        encoding="utf-8"
    )
    assert (
        "registry.threadforge.local:30500/mirror/docker.io/kindest/local-path-helper@sha256:d8a6cc3b66ff253e3adb1ed3017bd1556301a76bcb3a0d2a4db3c8eeb7f0fc0a"
        in text
    )
    assert "docker.io/kindest/local-path-helper:v20230510-486859a6" not in text
    assert "helperPod.yaml" in text
    assert "resources:" in text
    assert "requests:" in text
    assert "limits:" in text
