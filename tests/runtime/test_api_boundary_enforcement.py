"""Phase 10: API boundary enforcement tests.

These tests verify that the API layer extracts identity from headers
and enforces capabilities before passing to downstream handlers.
"""

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from runtime.api.identity_deps import extract_identity_from_headers, parse_spiffe_id
from runtime.identity.context import IdentityContext


def _proxy_header(spiffe_id: str) -> dict[str, str]:
    return {"x-forwarded-client-cert": f"URI={spiffe_id};Hash=test"}

# =============================================================================
# SPIFFE ID parsing tests
# =============================================================================


def test_parse_valid_spiffe_id():
    """Valid SPIFFE ID should parse correctly."""
    spiffe_id = "spiffe://identity.threadforge.local/ns/app/sa/worker/tier2"
    identity = parse_spiffe_id(spiffe_id)

    assert identity.spiffe_id == spiffe_id
    assert identity.trust_domain == "identity.threadforge.local"
    assert identity.namespace == "app"
    assert identity.service_account == "worker"
    assert identity.tier == "tier2"
    assert identity.attested is True


def test_parse_spiffe_id_without_tier():
    """SPIFFE ID without tier should parse with empty tier."""
    spiffe_id = "spiffe://identity.threadforge.local/ns/app/sa/worker"
    identity = parse_spiffe_id(spiffe_id)

    assert identity.tier == ""


def test_parse_invalid_spiffe_id_no_prefix():
    """Invalid SPIFFE ID without spiffe:// prefix should raise."""
    with pytest.raises(ValueError, match="Invalid SPIFFE ID format"):
        parse_spiffe_id("http://example.com/ns/app/sa/worker/tier2")


def test_parse_invalid_spiffe_id_malformed():
    """Malformed SPIFFE ID should raise."""
    with pytest.raises(ValueError, match="Malformed SPIFFE ID"):
        parse_spiffe_id("spiffe://domain/too/short")


def test_parse_invalid_spiffe_id_missing_ns():
    """SPIFFE ID without ns segment should raise."""
    with pytest.raises(ValueError, match="Expected 'ns'"):
        parse_spiffe_id("spiffe://domain/foo/bar/sa/svc/tier")


def test_parse_invalid_spiffe_id_missing_sa():
    """SPIFFE ID without sa segment should raise."""
    with pytest.raises(ValueError, match="Expected 'sa'"):
        parse_spiffe_id("spiffe://domain/ns/bar/foo/svc/tier")


# =============================================================================
# Header extraction tests
# =============================================================================


def test_extract_identity_from_x_spiffe_id_header():
    """x-spiffe-id header should be extracted correctly."""
    identity = extract_identity_from_headers(
        x_spiffe_id="spiffe://identity.threadforge.local/ns/sys/sa/admin/tier0",
        x_forwarded_client_cert=None,
    )

    assert identity is not None
    assert identity.tier == "tier0"
    assert identity.service_account == "admin"


def test_extract_identity_from_xfcc_header():
    """x-forwarded-client-cert header should be extracted correctly."""
    xfcc = "URI=spiffe://identity.threadforge.local/ns/app/sa/worker/tier2;Hash=abc123"
    identity = extract_identity_from_headers(
        x_spiffe_id=None,
        x_forwarded_client_cert=xfcc,
    )

    assert identity is not None
    assert identity.tier == "tier2"
    assert identity.service_account == "worker"


def test_extract_identity_x_spiffe_id_takes_priority():
    """x-spiffe-id should take priority over x-forwarded-client-cert."""
    identity = extract_identity_from_headers(
        x_spiffe_id="spiffe://identity.threadforge.local/ns/sys/sa/admin/tier0",
        x_forwarded_client_cert="URI=spiffe://identity.threadforge.local/ns/app/sa/worker/tier2",
    )

    assert identity is not None
    assert identity.tier == "tier0"  # From x-spiffe-id, not XFCC


def test_extract_identity_raises_401_when_no_headers():
    """No identity headers should raise 401 (fail-closed).

    Per Finding #4, all fallback paths are removed.
    Missing identity must raise immediately.
    """
    with pytest.raises(HTTPException) as exc_info:
        extract_identity_from_headers(
            x_spiffe_id=None,
            x_forwarded_client_cert=None,
        )
    assert exc_info.value.status_code == 401


def test_extract_identity_raises_400_for_invalid_header():
    """Invalid SPIFFE ID in header should raise 400 (malformed).

    Per Finding #4, malformed headers must be rejected, not silently ignored.
    """
    with pytest.raises(HTTPException) as exc_info:
        extract_identity_from_headers(
            x_spiffe_id="invalid-not-spiffe",
            x_forwarded_client_cert=None,
        )
    assert exc_info.value.status_code == 400


# =============================================================================
# Capability derivation at API boundary tests
# =============================================================================


def test_api_boundary_derives_capabilities_for_valid_identity():
    """Valid identity should have capabilities derived at API boundary."""
    from runtime.api.identity_deps import get_capabilities

    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/sys/sa/admin/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="sys",
        service_account="admin",
        attested=True,
    )

    caps = get_capabilities(identity)

    assert caps is not None
    assert "vector.write" in caps.capabilities
    assert "vector.read" in caps.capabilities


def test_api_boundary_returns_none_for_unmatched_policy():
    """Identity with no matching policy should return None capabilities."""
    from runtime.api.identity_deps import get_capabilities

    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/unknown/sa/unknown/unknowntier",
        trust_domain="identity.threadforge.local",
        tier="unknowntier",
        namespace="unknown",
        service_account="unknown",
        attested=True,
    )

    caps = get_capabilities(identity)
    assert caps is None


# =============================================================================
# FastAPI endpoint enforcement tests (integration)
# =============================================================================


@pytest.fixture
def test_client():
    """Create test client for API with mocked downstream."""
    from unittest.mock import patch

    from fastapi import FastAPI

    from runtime.api.router_api import router

    app = FastAPI()
    app.include_router(router, prefix="/v1")

    # Mock operator_core to avoid downstream failures
    with patch("runtime.api.router_api.operator_core") as mock_core:
        mock_core.return_value.execute.return_value = {"status": "ok"}
        client = TestClient(app)
        client._threadforge_operator_core_mock = mock_core
        yield client


def test_api_insert_without_identity_fails_mandatory_enforcement(test_client):
    """Insert without identity headers must FAIL (mandatory enforcement).

    With mandatory capability enforcement (Finding #1 fix), missing identity
    should result in 401/403 error, not silently succeed.
    """
    response = test_client.post(
        "/v1/insert",
        json={"id": "test", "vector": [1.0, 2.0]},
    )
    # MUST fail at API boundary (401 = missing auth, 403 = no capability)
    assert response.status_code in [401, 403], f"Expected 401 or 403, got {response.status_code}: {response.json()}"


def test_api_insert_with_malformed_spiffe_fails_mandatory_enforcement(test_client):
    """Insert with malformed SPIFFE ID must FAIL (mandatory enforcement).

    Malformed identity headers should be rejected, not silently ignored.
    """
    response = test_client.post(
        "/v1/insert",
        json={"id": "test", "vector": [1.0, 2.0]},
        headers={"x-spiffe-id": "not-a-valid-spiffe-id"},
    )
    # MUST fail at API boundary (400 = bad header, 401 = missing valid auth)
    assert response.status_code in [400, 401], f"Expected 400 or 401, got {response.status_code}: {response.json()}"


def test_api_insert_with_tier0_identity_succeeds(test_client):
    """Insert with tier0 identity should pass capability check."""
    response = test_client.post(
        "/v1/insert",
        json={"id": "test", "vector": [1.0, 2.0]},
        headers=_proxy_header("spiffe://identity.threadforge.local/ns/sys/sa/admin/tier0"),
    )
    # May fail downstream, but should pass API enforcement
    assert response.status_code in [200, 500]


def test_api_insert_with_tier3_identity_denied(test_client):
    """Insert with tier3 identity should be denied at API boundary."""
    response = test_client.post(
        "/v1/insert",
        json={"id": "test", "vector": [1.0, 2.0]},
        headers=_proxy_header("spiffe://identity.threadforge.local/ns/guest/sa/viewer/tier3"),
    )
    assert response.status_code == 403
    assert "vector.write" in response.json()["detail"]


def test_api_delete_with_tier2_identity_denied(test_client):
    """Delete with tier2 identity should be denied (no vector.write)."""
    response = test_client.post(
        "/v1/delete",
        json={"id": "test"},
        headers=_proxy_header("spiffe://identity.threadforge.local/ns/app/sa/worker/tier2"),
    )
    assert response.status_code == 403
    assert "vector.write" in response.json()["detail"]


def test_api_search_with_tier3_identity_succeeds(test_client):
    """Search with tier3 identity should pass (has vector.read)."""
    response = test_client.post(
        "/v1/search",
        json={"query": "test"},
        headers=_proxy_header("spiffe://identity.threadforge.local/ns/guest/sa/viewer/tier3"),
    )
    # May fail downstream, but should pass API enforcement
    assert response.status_code in [200, 500]


def test_api_search_denied_without_valid_identity(test_client):
    """Search must fail if request has no valid identity (mandatory enforcement).

    With Finding #1 fix, missing identity means 401/403, not bypass.
    """
    response = test_client.post(
        "/v1/search",
        json={"query": "test"},
        headers={
            # This tier doesn't exist, so no capabilities
            "x-forwarded-client-cert": "URI=spiffe://identity.threadforge.local/ns/unknown/sa/unknown/unknowntier;Hash=test"
        },
    )
    # With mandatory enforcement, missing policy = 403 (no capability)
    assert response.status_code == 403, f"Expected 403, got {response.status_code}: {response.json()}"


def test_api_embed_with_tier2_identity_denied(test_client):
    """Embed with tier2 identity should be denied (no vector.embed)."""
    response = test_client.post(
        "/v1/embed",
        json={"text": "test"},
        headers=_proxy_header("spiffe://identity.threadforge.local/ns/app/sa/worker/tier2"),
    )
    assert response.status_code == 403
    assert "vector.embed" in response.json()["detail"]


def test_api_embed_with_tier1_identity_succeeds(test_client):
    """Embed with tier1 identity should pass (has vector.embed)."""
    response = test_client.post(
        "/v1/embed",
        json={"text": "test"},
        headers=_proxy_header("spiffe://identity.threadforge.local/ns/sys/sa/svc/tier1"),
    )
    # May fail downstream, but should pass API enforcement
    assert response.status_code in [200, 500]


def test_api_embed_propagates_authenticated_identity_to_operator(test_client):
    """Embed must preserve the proxy-attested identity in its SMP envelope."""
    response = test_client.post(
        "/v1/embed",
        json={"text": "test"},
        headers=_proxy_header("spiffe://identity.threadforge.local/ns/sys/sa/svc/tier1"),
    )
    assert response.status_code in [200, 500]
    envelope = test_client._threadforge_operator_core_mock.return_value.execute.call_args.args[0]
    assert envelope.payload["_identity_ctx"] == {
        "spiffe_id": "spiffe://identity.threadforge.local/ns/sys/sa/svc/tier1",
        "trust_domain": "identity.threadforge.local",
        "attested": True,
        "policy": envelope.payload["_identity_ctx"]["policy"],
    }


def test_api_all_endpoints_require_identity(test_client):
    """All vector endpoints must require valid identity (mandatory enforcement).

    This is a regression test for Finding #1 (optional capability enforcement).
    All endpoints must fail without identity headers.
    """
    endpoints = [
        ("/v1/embed", {"text": "test"}),
        ("/v1/search", {"query": "test"}),
        ("/v1/insert", {"id": "test", "vector": [1.0, 2.0]}),
        ("/v1/delete", {"id": "test"}),
    ]

    for endpoint, payload in endpoints:
        response = test_client.post(endpoint, json=payload)
        assert response.status_code in [
            401,
            403,
        ], f"{endpoint} without identity should fail with 401/403, got {response.status_code}: {response.json()}"
