import pytest
from fastapi.testclient import TestClient

from runtime.api.app import app
from runtime.authority.state import AuthorityState, set_state

pytestmark = pytest.mark.unit


client = TestClient(app)


def test_healthz_endpoint_removed():
    """Per Finding #2, unauthenticated /healthz endpoint has been removed.

    Health checks must be enforced at Istio mTLS layer, not at application layer.
    Kubernetes probes should use mTLS client certificates.
    """
    # UNCLAIMED
    set_state(AuthorityState.UNCLAIMED, reason="test")
    r = client.get("/healthz")
    assert r.status_code == 404  # Endpoint removed

    # AUTHORITATIVE (still removed)
    set_state(AuthorityState.AUTHORITATIVE, reason="test")
    r2 = client.get("/healthz")
    assert r2.status_code == 404  # Endpoint removed
