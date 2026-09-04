import pytest

from runtime.telemetry.identity import extract_identity_context_from_envoy_metadata, extract_spiffe_from_envoy_metadata

pytestmark = pytest.mark.unit


def test_extract_spiffe_from_envoy_metadata_valid():
    ctx = {"peer_metadata": {"spiffe_id": "spiffe://trust_domain/ns/namespace/sa/service_account"}}
    assert extract_spiffe_from_envoy_metadata(ctx) == "spiffe://trust_domain/ns/namespace/sa/service_account"


def test_extract_identity_context_from_envoy_metadata_parses_components():
    ctx = {"peer_metadata": {"spiffe_id": "spiffe://tf.example/ns/default/sa/my-service"}}
    identity = extract_identity_context_from_envoy_metadata(ctx)
    assert identity is not None
    assert identity.spiffe_id.startswith("spiffe://")
    # Security requirement: attested MUST NOT be inferred from metadata alone.
    assert identity.attested is False
    assert identity.trust_domain == "tf.example"


def test_extract_identity_context_from_envoy_metadata_invalid_returns_none():
    # Missing peer_metadata
    assert extract_identity_context_from_envoy_metadata({}) is None

    # Malformed spiffe id
    ctx = {"peer_metadata": {"spiffe_id": "not-a-spiffe-id"}}
    assert extract_identity_context_from_envoy_metadata(ctx) is None


def test_extract_identity_context_spoof_protection():
    # Malformed-looking SPIFFE strings must be rejected and return None
    ctx = {"peer_metadata": {"spiffe_id": "spiffe://///"}}
    identity = extract_identity_context_from_envoy_metadata(ctx)
    assert identity is None
