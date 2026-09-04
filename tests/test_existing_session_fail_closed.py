from __future__ import annotations

from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def test_spire_csr_proof_ttl_is_short_lived() -> None:
    text = _read("platform/deploy/infra/spire-csr/spire-csr.yaml")

    assert "SPIRE_CSR_NAMESPACE_TTL_OVERRIDES" in text
    assert "threadforge-test=90" in text


def test_threadforge_test_destination_rule_bounds_connection_lifetime() -> None:
    text = _read("platform/deploy/infra/threadforge-test/enforce.yaml")

    assert "kind: DestinationRule" in text
    assert "name: echo-istio-mtls" in text
    assert "maxConnectionDuration: 75s" in text
    assert "idleTimeout: 15s" in text


def test_proof_wires_existing_session_fail_closed_guarantee() -> None:
    text = _read("scripts/prove_system.sh")

    assert 'EXISTING_SESSION_FAIL_CLOSED_STATUS="NOT_EVALUATED"' in text
    assert "verify_existing_session_fail_closed.sh" in text
    assert "existing_session_fail_closed=$EXISTING_SESSION_FAIL_CLOSED_STATUS" in text
    assert 'existing_session_fail_closed) EXISTING_SESSION_FAIL_CLOSED_STATUS="$v" ;;' in text
    assert '"existing_session_fail_closed": {"status": env("EXISTING_SESSION_FAIL_CLOSED_STATUS")' in text


def test_proof_artifacts_require_existing_session_evidence() -> None:
    manifest_text = _read("scripts/lib/proof_artifact_manifest.sh")
    verifier_text = _read("scripts/verify/verify_proof_artifacts.sh")
    schema_text = _read("scripts/verify/verify_determinism_schema.py")

    assert "existing_session_fail_closed.json" in manifest_text
    assert '"existing_session_fail_closed"' in verifier_text
    assert "existing_session_fail_closed invariant failed" in verifier_text
    assert '"existing_session_fail_closed"' in schema_text


def test_existing_session_verifier_accepts_iso8601_envoy_expiry() -> None:
    text = _read("scripts/verify/verify_existing_session_fail_closed.sh")

    assert "fromisoformat" in text
    assert "unsupported expiration_time format" in text


def test_verify_contract_mentions_existing_session_expiry_failure() -> None:
    text = _read("scripts/contracts/proof_phase_contracts.json")

    assert "existing proof sessions fail closed after SVID expiry when SPIRE is unavailable" in text
