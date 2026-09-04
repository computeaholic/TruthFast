from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def test_sidecar_policy_enforces_protected_namespaces_for_pods_and_controllers() -> None:
    policy = _read("platform/policies/require-istio-sidecar.yaml")

    assert "name: threadforge-require-istio-sidecar" in policy
    assert "threadforge-test" in policy
    assert "threadforge-system" in policy
    assert "- Pod" in policy
    assert "- Deployment" in policy
    assert "- StatefulSet" in policy
    assert "- Job" in policy
    assert 'sidecar.istio.io/inject" || "true"' in policy
    assert "spec.containers[?name=='istio-proxy'] | length(@)" in policy
    assert "spec.template.metadata.annotations" in policy
    assert "spec.template.spec.containers[?name=='istio-proxy'] | length(@)" not in policy


def test_bootstrap_applies_canonical_sidecar_policy() -> None:
    bootstrap = _read("scripts/infra/bootstrap.sh")
    assert "kubectl apply -f platform/policies/require-istio-sidecar.yaml" in bootstrap


def test_proof_wires_sidecar_enforcement_verifier_and_guarantee() -> None:
    prove = _read("scripts/prove_system.sh")
    verifier = _read("scripts/verify/verify_proof_artifacts.sh")
    schema = _read("scripts/verify/verify_determinism_schema.py")
    sidecar = _read("scripts/verify/verify_sidecar_enforcement.sh")

    assert "verify_sidecar_enforcement.sh" in prove
    assert 'SIDECAR_ENFORCEMENT_STATUS="NOT_EVALUATED"' in prove
    assert '"sidecar_enforcement":' in prove
    assert '"status": env("SIDECAR_ENFORCEMENT_STATUS")' in prove
    assert '"sidecar_enforcement": env("SIDECAR_ENFORCEMENT_STATUS")' in prove
    assert "sidecar_enforcement_validation.json" in prove

    assert "sidecar_enforcement_validation.json" in verifier
    assert '"sidecar_enforcement",' in verifier

    assert '"sidecar_enforcement",' in schema
    assert 'bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" >/dev/null' in sidecar
    assert 'bash "$REPO_ROOT/scripts/verify/wait_for_determinism_settle.sh" >/dev/null' in sidecar
    assert "run_dryrun_after_control_plane_wait" in sidecar
    assert "SIDECAR_ENFORCEMENT_RETRY_ATTEMPTS" not in sidecar
    assert "SIDECAR_ENFORCEMENT_RETRY_INTERVAL_SECONDS" not in sidecar
    assert "waiting for canonical control-plane convergence gate" in sidecar
    assert "self_heal_admission_webhooks" not in sidecar
    assert "scripts/proof/reconcile_webhook_ca_bundle.sh" not in sidecar
    assert "scripts/lib/reconcile_webhook_ca_bundle.sh" not in sidecar


def test_legacy_and_canonical_sidecar_policies_are_kept_in_sync() -> None:
    canonical = _read("platform/policies/require-istio-sidecar.yaml")
    legacy = _read("platform/deploy/infra/policy/require-istio-sidecar.yaml")
    assert canonical.strip() == legacy.strip()
