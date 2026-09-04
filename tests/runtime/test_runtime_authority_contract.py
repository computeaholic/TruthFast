"""Focused regressions for identity-first runtime authority boundaries."""

from __future__ import annotations

import socket
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi import HTTPException


def _socket_path(tmp_path):
    path = tmp_path / "spire-agent.sock"
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(str(path))
    sock.listen(1)
    return path, sock


def test_fresh_process_starts_unclaimed() -> None:
    result = subprocess.run(
        [sys.executable, "-c", "from runtime.authority.state import get_state; print(get_state().value)"],
        check=True,
        capture_output=True,
        text=True,
        env={"PYTHONPATH": "platform"},
    )
    assert result.stdout.strip() == "UNCLAIMED"


def test_missing_svid_client_cannot_synthesize_authority(monkeypatch, tmp_path) -> None:
    import runtime.spire.grpc_client as grpc_client
    import runtime.spire.workload as workload
    from runtime.authority.state import AuthorityState, get_state
    from runtime.start import _assert_identity_visibility

    socket_path, sock = _socket_path(tmp_path)
    monkeypatch.setenv("THREADFORGE_SPIRE_AGENT_SOCKET", str(socket_path))
    monkeypatch.setattr(workload, "is_workload_api_responsive", lambda _: True)

    def missing_client(_):
        raise grpc_client.GRPCClientError("pyspiffe library not available")

    monkeypatch.setattr(grpc_client, "fetch_and_validate_svid_via_grpc", missing_client)
    monkeypatch.setattr("runtime.authority.signing.load_authority_private_key", lambda: object())

    try:
        _assert_identity_visibility()
    finally:
        sock.close()

    assert get_state() == AuthorityState.UNCLAIMED


def test_validated_svid_is_required_for_authority(monkeypatch, tmp_path) -> None:
    import runtime.spire.grpc_client as grpc_client
    import runtime.spire.workload as workload
    from runtime.authority.state import AuthorityState, get_state
    from runtime.start import _assert_identity_visibility

    socket_path, sock = _socket_path(tmp_path)
    monkeypatch.setenv("THREADFORGE_SPIRE_AGENT_SOCKET", str(socket_path))
    monkeypatch.setattr(workload, "is_workload_api_responsive", lambda _: True)
    expiry = datetime.now(timezone.utc) + timedelta(hours=1)
    monkeypatch.setattr(
        grpc_client,
        "fetch_and_validate_svid_via_grpc",
        lambda _: ("spiffe://identity.threadforge.local/ns/threadforge/sa/threadforge-api", "sha3-512:test", expiry),
    )
    monkeypatch.setattr("runtime.authority.signing.load_authority_private_key", lambda: object())

    try:
        _assert_identity_visibility()
    finally:
        sock.close()

    assert get_state() == AuthorityState.AUTHORITATIVE


def test_canonical_api_identity_requires_proxy_xfcc() -> None:
    from runtime.api.identity_deps import extract_identity_from_proxy_headers

    with pytest.raises(HTTPException) as missing:
        extract_identity_from_proxy_headers()
    assert missing.value.status_code == 401

    with pytest.raises(HTTPException) as ambiguous:
        extract_identity_from_proxy_headers(
            "URI=spiffe://identity.threadforge.local/ns/sys/sa/admin/tier0;"
            "URI=spiffe://identity.threadforge.local/ns/guest/sa/viewer/tier3"
        )
    assert ambiguous.value.status_code == 401

    identity = extract_identity_from_proxy_headers(
        "By=spiffe://identity.threadforge.local/ns/istio-system/sa/istio-ingressgateway;"
        "URI=spiffe://identity.threadforge.local/ns/sys/sa/admin/tier0;Hash=abc123"
    )
    assert identity.spiffe_id.endswith("/ns/sys/sa/admin/tier0")


def test_legacy_api_cannot_become_independent_runtime_authority() -> None:
    """Keep the retired root API from regaining a separate trust boundary."""
    repo_root = Path(__file__).resolve().parents[2]

    assert not (repo_root / "api" / "Containerfile").exists()

    compat_app = (repo_root / "api" / "app.py").read_text()
    assert "from runtime.api.app import app" in compat_app
    assert "FastAPI(" not in compat_app
    assert "api.routes" not in compat_app
    assert "uvicorn.run" not in compat_app

    compat_deps = (repo_root / "api" / "deps.py").read_text()
    assert "extract_identity_from_proxy_headers" in compat_deps
    assert "x_threadforge_spiffe_id" not in compat_deps
    assert "Header(" not in compat_deps

    image = (repo_root / "platform" / "images" / "api" / "Dockerfile").read_text()
    deployment = (
        repo_root / "platform" / "deploy" / "services" / "api" / "templates" / "deployment.yaml"
    ).read_text()
    assert "runtime.api.app:app" in image
    assert "runtime.api.app:app" in deployment
