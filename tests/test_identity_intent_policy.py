from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def test_spiffe_identity_policy_uses_intent_not_status() -> None:
    policy = _read("platform/deploy/infra/policy/enforce-spire-only-certs.yaml")

    assert "name: threadforge-require-spiffe-identity" in policy
    assert "sidecar.istio.io/status" not in policy
    assert "name: require-mesh-namespace-label" in policy
    assert 'metadata.labels.\"istio-injection\"' in policy
    assert 'value: "enabled"' in policy
    assert "name: require-spiffe-compatible-service-account" in policy
    assert 'request.object.spec.serviceAccountName || ""' in policy
    assert "regex_match('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'" in policy
    assert "DNS-1123 compatible" in policy
    assert "name: deny-sidecar-opt-out" in policy
    assert "name: deny-sidecar-opt-out-controllers" in policy
    assert "name: deny-sidecar-opt-out-cronjobs" in policy
    assert "sidecar.istio.io/inject" in policy
    assert "value: \"false\"" in policy
    assert 'request.object.spec.serviceAccountName || "default"' in policy
    assert 'request.object.spec.template.spec.serviceAccountName || "default"' in policy
    assert 'request.object.spec.jobTemplate.spec.template.spec.serviceAccountName || "default"' in policy
    assert '- CronJob' in policy
    assert '- DaemonSet' in policy
    assert 'request.object.spec.jobTemplate.spec.template.metadata.annotations."sidecar.istio.io/inject"' in policy
    assert 'request.object.spec.template.metadata.annotations."sidecar.istio.io/inject"' in policy
    assert "name: deny-citadel-env-cronjobs" in policy


def test_identity_intent_policy_targets_identity_namespaces() -> None:
    policy = _read("platform/deploy/infra/policy/enforce-spire-only-certs.yaml")
    assert "- kube-system" in policy
    assert "- istio-system" in policy
    assert "- spire-system" in policy
    assert 'metadata.labels."istio-injection" || ""' in policy
