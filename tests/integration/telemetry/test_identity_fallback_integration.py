import os

import pytest

from runtime.telemetry.identity_helpers import get_identity_context_from_event

pytestmark = pytest.mark.integration


def test_identity_fallback_integration(monkeypatch):
    # Integration preflight: require explicit flag to run
    if os.getenv("ENABLE_METADATA_FALLBACK", "false").lower() != "true":
        raise RuntimeError("ENABLE_METADATA_FALLBACK not set to 'true' - cannot run integration test (fail loudly)")

    event = {"peer_metadata": {"spiffe_id": "spiffe://tf.example/ns/ns/sa/s"}}
    ic = get_identity_context_from_event(event)
    assert ic is not None
    assert ic.attested is False
