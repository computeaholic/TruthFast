import hashlib
import os
import socket


from runtime.telemetry.phase_b_runtime import (
    PhaseBMonitor,
    StartupState,
)

from tests.test_phase_b_runtime import _run_test_server


def _write_cert_file(tmp_path, content: bytes) -> str:
    p = tmp_path / "PHASE_A_CERTIFICATION_VERDICT.md"
    p.write_bytes(content)
    return str(p)


def test_expected_cert_hash_match_and_mismatch(tmp_path, monkeypatch):
    # create cert file
    cert_path = _write_cert_file(tmp_path, b"cert-content")
    # compute actual hash
    actual = hashlib.sha256(b"cert-content").hexdigest()

    # ensure module will find the file by monkeypatching cwd lookup
    monkeypatch.chdir(tmp_path)

    # case: matches expected
    monkeypatch.setenv("KUBERNETES_SERVICE_HOST", "127.0.0.1")
    monkeypatch.setattr("runtime.telemetry.phase_b_runtime.EXPECTED_CERT_HASH", actual, raising=True)

    payload = "decision_signature_verification_failures_total 0\n"
    url, close = _run_test_server(payload)
    try:
        m = PhaseBMonitor(url, timeout=1.0)
        inv = m.verify_startup_invariants()
        assert inv["details"]["cert_hash_checked"] is True
        assert inv["details"]["cert_hash_matches"] is True
        assert inv["ready"] is True
    finally:
        close()

    # case: mismatch
    monkeypatch.setattr("runtime.telemetry.phase_b_runtime.EXPECTED_CERT_HASH", "deadbeef", raising=True)
    url, close = _run_test_server(payload)
    try:
        m = PhaseBMonitor(url, timeout=1.0)
        inv = m.verify_startup_invariants()
        # authenticity mismatch should cause degraded readiness
        assert inv["details"]["cert_hash_matches"] is False
        assert inv["ready"] is False
        assert m.start() == StartupState.DEGRADED
    finally:
        close()


def test_metrics_http_status_non200_classified(monkeypatch):
    # cert present
    monkeypatch.setattr(os.path, "exists", lambda p: True)
    monkeypatch.setenv("KUBERNETES_SERVICE_HOST", "127.0.0.1")

    payload = "decision_signature_verification_failures_total 0\n"
    url, close = _run_test_server(payload, status=500)
    try:
        m = PhaseBMonitor(url, timeout=1.0)
        inv = m.verify_startup_invariants()
        assert inv["ready"] is False
        d = inv["details"]
        assert d["metrics_failure_reason"] == "http_status"
        assert d["metrics_http_status"] == 500
    finally:
        close()


def test_metrics_missing_metric_classified(monkeypatch):
    monkeypatch.setattr(os.path, "exists", lambda p: True)
    monkeypatch.setenv("KUBERNETES_SERVICE_HOST", "127.0.0.1")

    payload = "some_other_metric 1\n"
    url, close = _run_test_server(payload)
    try:
        m = PhaseBMonitor(url, timeout=1.0)
        inv = m.verify_startup_invariants()
        assert inv["ready"] is False
        assert inv["details"]["metrics_failure_reason"] == "missing_metric"
    finally:
        close()


def test_fetch_metrics_timeout_classified(monkeypatch):
    monkeypatch.setattr(os.path, "exists", lambda p: True)
    monkeypatch.setenv("KUBERNETES_SERVICE_HOST", "127.0.0.1")

    def _raise_timeout(*a, **k):
        raise socket.timeout("timed out")

    monkeypatch.setattr("urllib.request.urlopen", _raise_timeout)
    m = PhaseBMonitor("http://127.0.0.1:1/metrics", timeout=0.01)
    inv = m.verify_startup_invariants()
    assert inv["ready"] is False
    assert inv["details"]["metrics_failure_reason"] == "timeout"


def test_timeout_clamped():
    m = PhaseBMonitor("http://127.0.0.1:1/metrics", timeout=10.0)
    assert m.timeout == 3.0


def test_version_below_minimum_sets_active_with_warning(tmp_path, monkeypatch):
    # create cert file and set expected hash to match
    cert_path = _write_cert_file(tmp_path, b"cert-content")
    actual = hashlib.sha256(b"cert-content").hexdigest()
    monkeypatch.setenv("KUBERNETES_SERVICE_HOST", "127.0.0.1")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr("runtime.telemetry.phase_b_runtime.EXPECTED_CERT_HASH", actual, raising=True)

    # set versions below minimum
    monkeypatch.setenv("KUBERNETES_VERSION", "1.20.0")
    monkeypatch.setenv("SPIRE_VERSION", "1.2.0")

    payload = "decision_signature_verification_failures_total 0\n"
    url, close = _run_test_server(payload)
    try:
        m = PhaseBMonitor(url, timeout=1.0)
        status = m.start()
        assert status == StartupState.ACTIVE_WITH_WARNING
        inv = m.verify_startup_invariants()
        assert inv["details"]["kubernetes_supported"] is False
        assert inv["details"]["spire_supported"] is False
    finally:
        close()
