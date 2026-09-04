import pytest

from runtime.telemetry.identity_helpers import get_identity_context_from_event

pytestmark = pytest.mark.unit


def test_returns_existing_identity_context_dict():
    event = {"identity_context": {"spiffe_id": "spiffe://x"}}
    assert get_identity_context_from_event(event) == {"spiffe_id": "spiffe://x"}


def test_fallback_disabled_by_default(monkeypatch):
    monkeypatch.delenv("ENABLE_METADATA_FALLBACK", raising=False)
    event = {"peer_metadata": {"spiffe_id": "spiffe://tf.example/ns/ns/sa/s"}}
    assert get_identity_context_from_event(event) is None


def test_fallback_enabled_parses_valid_metadata(monkeypatch):
    monkeypatch.setenv("ENABLE_METADATA_FALLBACK", "true")
    event = {"peer_metadata": {"spiffe_id": "spiffe://tf.example/ns/ns/sa/s"}}
    ic = get_identity_context_from_event(event)
    assert ic is not None
    assert ic.attested is False


def test_fallback_rejects_malformed(monkeypatch):
    monkeypatch.setenv("ENABLE_METADATA_FALLBACK", "true")
    event = {"peer_metadata": {"spiffe_id": "spiffe://///"}}
    ic = get_identity_context_from_event(event)
    assert ic is None


def test_attested_never_inferred(monkeypatch):
    # Ensure metadata-derived identities are always non-attested (attested=False)
    monkeypatch.setenv("ENABLE_METADATA_FALLBACK", "true")
    event = {"peer_metadata": {"spiffe_id": "spiffe://tf.example/ns/ns/sa/s"}}
    ic = get_identity_context_from_event(event)
    assert ic is not None
    assert ic.attested is False
