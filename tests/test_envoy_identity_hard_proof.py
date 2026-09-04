from pathlib import Path

import pytest


pytestmark = pytest.mark.core


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_envoy_identity_validator_requires_live_traffic_and_proxy_log_spiffe_evidence() -> None:
    text = (REPO_ROOT / "scripts/verify/validate_envoy_identity.sh").read_text()

    assert '"source_deployment": "test-client"' in text
    assert '"destination_deployment": "echo"' in text
    assert '"target_url": "http://echo.threadforge-test.svc.cluster.local/healthz"' in text
    assert '"curl",' in text
    assert '"-sv",' in text
    assert '"-w",' in text
    assert '"%{http_code}",' in text
    assert '"localhost:15000/certs"' in text
    assert '"logs",' in text
    assert "spiffe://" in text
    assert "proxy logs do not expose workload SPIFFE IDs after live traffic" in text


def test_prove_system_requires_hard_envoy_identity_evidence() -> None:
    text = (REPO_ROOT / "scripts/prove_system.sh").read_text()

    assert 'summary.get("traffic_proven") is not True' in text
    assert 'summary.get("spiffe_log_evidence") is not True' in text
    assert 'source.get("observed_spiffe_ids") != [source.get("expected_spiffe_id")]' in text
    assert 'destination.get("observed_spiffe_ids") != [destination.get("expected_spiffe_id")]' in text
    assert 'str(traffic.get("http_status")) != "200"' in text
    assert "proxy logs did not expose the expected workload SPIFFE IDs" in text


def test_prove_system_anchors_trust_lineage_to_active_state_not_stale_artifact() -> None:
    text = (REPO_ROOT / "scripts/prove_system.sh").read_text()

    assert "trust_authority_state.json" in text
    assert "active_root_fingerprint" in text
    assert "active_root_serial" in text
    assert "istio-ca-root-cert root set mismatch" in text
    assert "cacerts root-cert.pem root set mismatch" in text
    assert "strict mode requires Envoy /certs root serial to be in active SPIRE bundle lineage" in text
    assert "must contain exactly one root" not in text
