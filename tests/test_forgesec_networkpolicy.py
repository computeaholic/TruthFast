from pathlib import Path


def test_forgesec_networkpolicy_allows_kubernetes_api_and_runtime_targets() -> None:
    text = Path("platform/deploy/forgesec/networkpolicy.yaml").read_text(encoding="utf-8")

    assert "name: forgesec-egress-strict" in text
    assert "kubernetes.io/metadata.name: kube-system" in text
    assert "port: 6443" in text
    assert "kubernetes.io/metadata.name: threadforge-system" in text
    assert "kubernetes.io/metadata.name: observability" in text
    assert "kubernetes.io/metadata.name: minio" in text
