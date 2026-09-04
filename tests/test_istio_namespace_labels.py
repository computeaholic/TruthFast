from pathlib import Path

import pytest
import yaml

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parent.parent
BOOTSTRAP = ROOT / "scripts" / "infra" / "bootstrap.sh"
MANIFEST_GLOBS = ("platform/deploy/**/*.yaml", "platform/deploy/**/*.yml")

REQUIRED_NAMESPACE_LABELS = {
    "observability": "enabled",
    "threadforge-system": "enabled",
    "threadforge-test": "enabled",
    "cert-manager": "disabled",
    "default": "disabled",
    "forgesec": "enabled",
    "kyverno": "disabled",
    "minio": "enabled",
    "spire-system": "disabled",
}


def _iter_yaml_paths():
    seen = set()
    for pattern in MANIFEST_GLOBS:
        for path in ROOT.glob(pattern):
            if path in seen or not path.is_file():
                continue
            seen.add(path)
            yield path


def _namespace_label_from_manifest(path: Path, namespace: str):
    try:
        documents = list(yaml.safe_load_all(path.read_text()))
    except yaml.YAMLError:
        return None

    for document in documents:
        if not isinstance(document, dict) or document.get("kind") != "Namespace":
            continue
        metadata = document.get("metadata") or {}
        if metadata.get("name") != namespace:
            continue
        labels = metadata.get("labels") or {}
        return labels.get("istio-injection"), path.relative_to(ROOT)
    return None


def test_bootstrap_namespaces_explicitly_declare_istio_injection():
    manifest_sources = {}
    for path in _iter_yaml_paths():
        for namespace in REQUIRED_NAMESPACE_LABELS:
            match = _namespace_label_from_manifest(path, namespace)
            if match is not None:
                manifest_sources[namespace] = match

    bootstrap_text = BOOTSTRAP.read_text()
    missing = []
    mismatched = []

    for namespace, expected in REQUIRED_NAMESPACE_LABELS.items():
        manifest_match = manifest_sources.get(namespace)
        if manifest_match is not None:
            actual, source = manifest_match
            if actual != expected:
                mismatched.append(f"{namespace} manifest {source} expected {expected} got {actual}")
            continue

        bootstrap_snippet = f"label_namespace_injection {namespace} {expected}"
        if bootstrap_snippet not in bootstrap_text:
            missing.append(namespace)

    assert not missing, "Namespaces missing explicit istio-injection management: " + ", ".join(sorted(missing))
    assert not mismatched, "Namespace manifests have incorrect istio-injection labels:\n" + "\n".join(
        sorted(mismatched)
    )


def test_threadforge_test_namespace_has_canonical_manifest() -> None:
    namespace_manifest = ROOT / "platform" / "deploy" / "infra" / "threadforge-test" / "namespace.yaml"
    assert namespace_manifest.exists()
    text = namespace_manifest.read_text()
    assert "kind: Namespace" in text
    assert "name: threadforge-test" in text
    assert "istio-injection: enabled" in text
    assert "sidecar.istio.io/proxyImage" in text
    assert "registry.threadforge.local:30500/istio/proxyv2@sha256:2f78ddd13cbf6f600c8bebb9f05b21f9b14e047ec5f8c88ef9f50abc8e14466b" in text
    bootstrap_text = BOOTSTRAP.read_text()
    assert "ensure_threadforge_test_namespace() {" in bootstrap_text
    assert 'kubectl apply -f platform/deploy/infra/threadforge-test/namespace.yaml >/dev/null' in bootstrap_text
    assert 'kubectl get namespace threadforge-test >/dev/null 2>&1' in bootstrap_text
    assert bootstrap_text.count("ensure_threadforge_test_namespace") >= 4
    assert bootstrap_text.count('kubectl apply -f platform/deploy/infra/threadforge-test/namespace.yaml >/dev/null') == 1


def test_threadforge_test_workloads_pin_proxy_image() -> None:
    enforce_manifest = ROOT / "platform" / "deploy" / "infra" / "threadforge-test" / "enforce.yaml"
    text = enforce_manifest.read_text(encoding="utf-8")
    assert text.count("sidecar.istio.io/proxyImage") >= 2
    assert text.count(
        "registry.threadforge.local:30500/istio/proxyv2@sha256:2f78ddd13cbf6f600c8bebb9f05b21f9b14e047ec5f8c88ef9f50abc8e14466b"
    ) >= 2


def test_threadforge_test_injection_probe_is_policy_compliant() -> None:
    probe_manifest = ROOT / "platform" / "deploy" / "infra" / "threadforge-test" / "test-injection.yaml"
    assert probe_manifest.exists()
    text = probe_manifest.read_text()
    assert "kind: ServiceAccount" in text
    assert "name: test-injection-sa" in text
    assert "kind: Pod" in text
    assert "serviceAccountName: test-injection-sa" in text
    assert "resources:" in text
    assert "cpu: 10m" in text
    assert "memory: 32Mi" in text
    assert "@sha256:" in text
    assert "registry.threadforge.local:30500/mirror/docker.io/curlimages/curl@sha256:846c5f0324b40f833b9a1fa3d5a667ac0f2b4712c9a39cae8cafe890286c52f2" in text
    assert 'kubectl apply -f platform/deploy/infra/threadforge-test/test-injection.yaml >/dev/null' in BOOTSTRAP.read_text()
