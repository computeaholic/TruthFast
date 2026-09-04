from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def test_canonical_east_west_policies_lock_threadforge_test_and_observability() -> None:
    default_deny = _read("platform/policies/default-deny-threadforge-test.yaml")
    observability = _read("platform/policies/observability-restrict.yaml")
    threadforge_test = _read("platform/deploy/infra/threadforge-test/enforce.yaml")

    assert "name: deny-all" in default_deny
    assert "namespace: threadforge-test" in default_deny
    assert "name: allow-ingress-to-echo" in default_deny
    assert "ns/observability/sa/prometheus" in default_deny

    assert "name: observability-deny-threadforge-test" in observability
    assert "name: observability-allow-internal" in observability
    assert "threadforge-test" in observability
    assert "observability" in observability

    assert "name: deny-all" in threadforge_test
    assert "name: allow-ingress-to-echo" in threadforge_test


def test_bootstrap_applies_east_west_policy_bundle() -> None:
    bootstrap = _read("scripts/infra/bootstrap.sh")

    assert "kubectl apply -f platform/policies/default-deny-threadforge-test.yaml" in bootstrap
    assert "kubectl apply -f platform/policies/observability-restrict.yaml" in bootstrap


def test_proof_wires_east_west_isolation_verifier_and_guarantee() -> None:
    prove = _read("scripts/prove_system.sh")
    verifier = _read("scripts/verify/verify_proof_artifacts.sh")
    schema = _read("scripts/verify/verify_determinism_schema.py")
    manifest = _read("scripts/lib/proof_artifact_manifest.sh")
    contracts = _read("scripts/contracts/proof_phase_contracts.json")

    assert "verify_east_west_blocking.sh" in prove
    assert 'EAST_WEST_ISOLATION_STATUS="NOT_EVALUATED"' in prove
    assert '"east_west_isolation": {"status": env("EAST_WEST_ISOLATION_STATUS")' in prove
    assert "east_west_isolation.json" in prove

    assert "east_west_isolation.json" in manifest
    assert '"east_west_isolation",' in verifier
    assert "east_west_isolation invariant failed" in verifier
    assert '"east_west_isolation",' in schema
    assert "east-west isolation blocks threadforge-test from observability" in contracts


def test_prometheus_inbound_allow_no_longer_has_port_only_fail_open_rule() -> None:
    prometheus_identity = _read("platform/deploy/infra/prometheus-operator/templates/prometheus-identity.yaml")

    assert "name: prometheus-inbound-allow" in prometheus_identity
    assert 'ports: ["9090"]' in prometheus_identity
    assert '\n      to:\n        - operation:\n            ports: ["9090"]' in prometheus_identity
    assert '\n    - to:\n        - operation:\n            ports: ["9090"]' not in prometheus_identity
