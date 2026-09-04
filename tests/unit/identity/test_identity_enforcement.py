"""Unit tests for HTTP API identity enforcement.

These tests validate the compatibility API's fail-closed identity behavior. They
intentionally do not assert mesh integration or SPIFFE issuance; those require
runtime evidence.
"""

import sys
from unittest.mock import Mock

import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

pytestmark = pytest.mark.unit

VALID_ID = "spiffe://identity.threadforge.local/ns/threadforge/sa/operator-ai"
FOREIGN_ID = "spiffe://foreign.example/ns/test/sa/x"


@pytest.fixture(autouse=True)
def _stub_external_dependencies(monkeypatch):
    """Provide lightweight stubs for compatibility-only backend dependencies."""
    monkeypatch.setitem(sys.modules, "minio", Mock())
    monkeypatch.setitem(sys.modules, "runtime.ai.minio_skillpack", Mock())
    monkeypatch.setitem(sys.modules, "runtime.ai.traffic", Mock())
    monkeypatch.setitem(sys.modules, "runtime.ai.vector_executor", Mock())
    monkeypatch.setitem(sys.modules, "runtime.core.signal_fabric", Mock())
    monkeypatch.setitem(sys.modules, "runtime.operator_logic", Mock())
    yield


@pytest.fixture
def client():
    from api.deps import extract_spiffe_identity

    app = FastAPI()

    @app.get("/identity")
    def identity(spiffe_id: str = Depends(extract_spiffe_identity)):
        return {"spiffe_id": spiffe_id}

    return TestClient(app)


def _xfcc(spiffe_id: str) -> str:
    return (
        "By=spiffe://identity.threadforge.local/ns/istio-system/sa/istio-ingressgateway;"
        f"URI={spiffe_id};Hash=abc123"
    )


def test_request_without_proxy_identity_returns_401(client):
    response = client.get("/identity")
    assert response.status_code == 401
    assert response.json()["detail"] == "Authenticated proxy identity required"


def test_caller_asserted_threadforge_spiffe_header_is_rejected(client):
    """A caller cannot choose its ThreadForge principal with a raw header."""
    response = client.get(
        "/identity",
        headers={"x-threadforge-spiffe-id": VALID_ID},
    )
    assert response.status_code == 401
    assert response.json()["detail"] == "Authenticated proxy identity required"


def test_valid_single_proxy_xfcc_identity_succeeds(client):
    response = client.get(
        "/identity",
        headers={"x-forwarded-client-cert": _xfcc(VALID_ID)},
    )
    assert response.status_code == 200
    assert response.json() == {"spiffe_id": VALID_ID}


def test_malformed_proxy_identity_fails_closed(client):
    response = client.get(
        "/identity",
        headers={"x-forwarded-client-cert": _xfcc("identity.threadforge.local/ns/test/sa/test")},
    )
    assert response.status_code == 401
    assert response.json()["detail"] == "Authenticated proxy identity is invalid"


def test_ambiguous_proxy_identity_fails_closed(client):
    response = client.get(
        "/identity",
        headers={
            "x-forwarded-client-cert": (
                f"URI={VALID_ID};"
                "URI=spiffe://identity.threadforge.local/ns/threadforge/sa/viewer"
            )
        },
    )
    assert response.status_code == 401
    assert response.json()["detail"] == "Authenticated proxy identity missing or ambiguous"


def test_foreign_trust_domain_fails_closed(client):
    response = client.get(
        "/identity",
        headers={"x-forwarded-client-cert": _xfcc(FOREIGN_ID)},
    )
    assert response.status_code == 401
    assert response.json()["detail"] == "Authenticated proxy identity is invalid"


def test_raw_header_cannot_override_proxy_identity(client):
    """Even when both headers exist, the proxy-produced XFCC is authoritative."""
    response = client.get(
        "/identity",
        headers={
            "x-threadforge-spiffe-id": "spiffe://identity.threadforge.local/ns/sys/sa/admin/tier0",
            "x-forwarded-client-cert": _xfcc(VALID_ID),
        },
    )
    assert response.status_code == 200
    assert response.json() == {"spiffe_id": VALID_ID}
