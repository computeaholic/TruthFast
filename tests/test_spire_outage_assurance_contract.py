from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def test_spire_outage_assurance_is_explicit_and_keeps_normal_proof_separate() -> None:
    makefile = _read("Makefile")
    wrapper = _read("scripts/verify/prove_spire_outage.sh")
    verifier = _read("scripts/verify/verify_existing_session_fail_closed.sh")

    assert "prove-spire-outage:" in makefile
    assert "make proof" not in wrapper
    assert "I_UNDERSTAND_THIS_IS_A_CONTROLLED_BREAKGLASS_EXPERIMENT" in wrapper
    assert 'artifact.get("spire_outage") != "policy_blocked"' in wrapper
    assert 'OUTAGE_SCALE_AS_USER="$BREAKGLASS_USER"' in wrapper
    assert 'OUTAGE_SCALE_AS_GROUP="$BREAKGLASS_GROUP"' in wrapper
    assert "record_breakglass_scale" in verifier
    assert '"post_restore_allowed_path"' in verifier
    assert '"workload_identity_recovered"' in verifier
    assert 'artifact["recovery_scope"] = "workload"' in verifier


def test_spire_outage_artifact_requires_bounded_recovery_evidence() -> None:
    wrapper = _read("scripts/verify/prove_spire_outage.sh")

    for field in (
        '"source_sha"',
        '"source_worktree_diff_hash"',
        '"run_id"',
        '"breakglass_authority"',
        '"spire_outage_observed"',
        '"baseline_session_established"',
        '"svid_serial"',
        '"svid_expiration"',
        '"post_expiry_existing_session_result"',
        '"fresh_request_during_outage_result"',
        '"spire_restored"',
        '"workload_identity_recovered"',
        '"recovery_scope"',
        '"breakglass_audit_present"',
        '"final"',
    ):
        assert field in wrapper

    assert '"ls-files", "--others", "--exclude-standard", "-z"' in wrapper
    assert 'digest.update((root / relative.decode()).read_bytes())' in wrapper


def test_spire_outage_recovery_does_not_claim_global_identity_reconvergence() -> None:
    verifier = _read("scripts/verify/verify_existing_session_fail_closed.sh")
    wrapper = _read("scripts/verify/prove_spire_outage.sh")

    assert 'artifact["identity_reconverged"]' not in verifier
    assert 'actual.get("identity_reconverged")' not in wrapper
    assert 'artifact["workload_identity_recovered"] = True' in verifier
    assert 'actual.get("workload_identity_recovered") is not True' in wrapper
