from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_trust_root_verification_has_dedicated_bounded_timeout():
    text = (REPO_ROOT / "scripts" / "prove_system.sh").read_text()

    expected = (
        '_run_subscript_with_timeout '
        '"${TRUST_ROOT_VERIFICATION_TIMEOUT_SECONDS:-120}" '
        '"$REPO_ROOT/scripts/verify/verify_trust_root_immutability.sh"'
    )

    # Capture and drift must both use the dedicated bounded timeout.
    assert text.count(expected) == 2


def test_generic_proof_check_timeout_remains_ten_seconds():
    text = (REPO_ROOT / "scripts" / "prove_system.sh").read_text()

    # This repair must not inflate the generic check budget.
    assert 'CHECK_TIMEOUT_SECONDS="${CHECK_TIMEOUT_SECONDS:-10}"' in text


def test_gateway_ca_source_has_dedicated_bounded_timeout():
    text = (REPO_ROOT / "scripts" / "prove_system.sh").read_text()

    expected = (
        '_run_subscript_with_timeout '
        '"${GATEWAY_CA_SOURCE_TIMEOUT_SECONDS:-120}" '
        '"$REPO_ROOT/scripts/verify/verify_gateway_ca_source.sh"'
    )
    assert expected in text
