from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def test_threadforge_ingress_is_no_longer_wildcard_open() -> None:
    ingress = _read("platform/deploy/infra/threadforge-test/ingress.yaml")

    assert 'hosts:\n        - "echo.threadforge.local"' in ingress
    assert 'hosts:\n    - "echo.threadforge.local"' in ingress
    assert 'exact: "/"' in ingress
    assert 'exact: "/health"' in ingress
    assert 'exact: "/healthz"' in ingress
    assert 'prefix: "/"' not in ingress
    assert '- "*"' not in ingress


def test_ingress_authz_allows_only_declared_host_and_paths() -> None:
    ingress = _read("platform/deploy/infra/threadforge-test/ingress.yaml")

    assert "name: threadforge-test-ingress-allow" in ingress
    assert 'ports:\n              - "80"' in ingress
    assert 'hosts:\n              - "echo.threadforge.local"' in ingress
    assert 'paths:\n              - "/"\n              - "/health"\n              - "/healthz"' in ingress
    assert "- {} # allow all" not in ingress


def test_registry_hardening_script_is_wired_into_bootstrap_and_reset() -> None:
    bootstrap = _read("scripts/infra/bootstrap.sh")
    reset = _read("scripts/ci/reset_ci_cluster.sh")
    harden = _read("scripts/infra/harden_local_registry.sh")
    probe = _read("scripts/lib/registry_probe.sh")

    assert "harden_local_registry.sh" in bootstrap
    assert "harden_local_registry.sh" in reset
    assert "REGISTRY_AUTH=htpasswd" in harden
    assert "registry.htpasswd" in harden
    assert '"${REGISTRY_PORT}:${REGISTRY_PORT}"' in harden
    assert "-p 30500:30500" in reset
    assert "reconcile_registry_dns" in harden
    assert "deployment/coredns" in harden
    assert "registry_probe_authenticated_status" in harden
    assert "registry_probe_anonymous_status" in harden
    assert "registry_probe_resolve" in probe
    assert "127.0.0.1" in probe
    assert "172.18.0.3" not in probe
    bootstrap = _read("scripts/infra/bootstrap.sh")
    ci_provision = _read("scripts/ci/provision_ci_disposable_certs.sh")
    registry_config = _read("scripts/lib/registry_config.sh")
    assert "registry_config_write" in bootstrap
    assert "addr: :${registry_port}" in registry_config
    assert "addr: :${REGISTRY_PORT}" in ci_provision


def test_local_registry_restart_uses_durable_config_artifact() -> None:
    harden = _read("scripts/infra/harden_local_registry.sh")

    durable_branch = harden.index('mode=local-durable-config')
    mounted_lookup = harden.index('mounted_config_path="$(docker inspect')

    assert durable_branch < mounted_lookup
    assert 'install -m 0644 "$mounted_config_path" "${local_config_fallback}"' in harden
    assert '-v "$config_path:/etc/docker/registry/config.yml:ro"' in harden


def test_test_client_uses_collector_for_otlp_and_tempo_stays_denied() -> None:
    collector = _read("platform/deploy/infra/otel/collector-authz.yaml")
    observability = _read("platform/policies/observability-restrict.yaml")
    verifier = _read("scripts/verify/verify_north_south_boundary.sh")

    assert 'namespaces: ["threadforge-system", "threadforge-test"]' in collector
    assert 'ports: ["4317", "4318"]' in collector
    assert 'methods: ["POST", "GET"]' in collector
    assert "name: observability-deny-threadforge-test" in observability
    assert "app: tempo" in observability
    assert 'source "$REPO_ROOT/scripts/lib/registry_probe.sh"' in verifier
    assert "registry_probe_authenticated_status" in verifier
    assert "https://registry.threadforge.local:30500/v2/" not in verifier


def test_proof_wires_north_south_boundary_guarantee_and_artifact() -> None:
    prove = _read("scripts/prove_system.sh")
    verifier = _read("scripts/verify/verify_proof_artifacts.sh")
    schema = _read("scripts/verify/verify_determinism_schema.py")
    manifest = _read("scripts/lib/proof_artifact_manifest.sh")

    assert 'NORTH_SOUTH_BOUNDARY_STATUS="NOT_EVALUATED"' in prove
    assert "verify_north_south_boundary.sh" in prove
    assert "north_south_boundary=$NORTH_SOUTH_BOUNDARY_STATUS" in prove
    assert '"north_south_boundary": {"status": env("NORTH_SOUTH_BOUNDARY_STATUS")' in prove
    assert 'doc["north_south_boundary"] = env("NORTH_SOUTH_BOUNDARY_STATUS")' in prove
    assert "north_south_boundary.json" in prove

    assert "north_south_boundary invariant failed" in verifier
    assert '"north_south_boundary",' in verifier
    assert '"north_south_boundary",' in schema
    assert "north_south_boundary.json" in manifest
