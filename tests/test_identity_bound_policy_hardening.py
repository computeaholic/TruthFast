from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_threadforge_test_allowlist_excludes_default_service_account() -> None:
    manifest = (REPO_ROOT / "platform/deploy/infra/threadforge-test/enforce.yaml").read_text()

    assert "spiffe://identity.threadforge.local/ns/threadforge-test/sa/test-client" in manifest
    assert "spiffe://identity.threadforge.local/ns/threadforge-test/sa/default" not in manifest
    assert "identity.threadforge.local/ns/threadforge-test/sa/default" not in manifest


def test_identity_bound_verifier_requires_distinct_spiffe_ids_and_strict_denial() -> None:
    verifier = (REPO_ROOT / "scripts/verify/verify_identity_bound_policy.sh").read_text()

    assert "STRICT PeerAuthentication not found" in verifier
    assert 'bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" >/dev/null' in verifier
    assert "waiting for canonical control-plane convergence gate" in verifier
    assert "self_heal_admission_webhooks" not in verifier
    assert "allow-ingress-to-echo still includes spoof principal" in verifier
    assert "allowed pod principal mismatch" in verifier
    assert "spoof pod principal mismatch" in verifier
    assert "IDENTITY_POLICY_BYPASS: spoof admission probe was not denied" in verifier
    assert "admission webhook unavailable during identity policy probe" in verifier
    assert "spoof admission probe" in verifier
    assert "istioctl proxy-config secret" not in verifier
    assert "proxy-config secret" not in verifier
    assert "capture_envoy_secrets" in verifier
    assert "127.0.0.1:15000/certs" in verifier
    assert "curl -sv --max-time 10" in verifier
