import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from runtime.telemetry.phase_b_runtime import PhaseBMonitor, PhaseBMonitorError


class _MetricsHandler(BaseHTTPRequestHandler):
    response_text = ""
    response_delay = 0.0
    response_status = 200

    def do_GET(self):
        if self.response_delay:
            time.sleep(self.response_delay)
        self.send_response(self.response_status)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.end_headers()
        self.wfile.write(self.response_text.encode())

    def log_message(self, format, *args):  # silence test output
        return


def _run_test_server(payload: str, delay: float = 0.0, status: int = 200):
    handler = type(
        "H",
        (_MetricsHandler,),
        {"response_text": payload, "response_delay": delay, "response_status": status},
    )
    server = HTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    port = server.server_address[1]
    url = f"http://127.0.0.1:{port}/metrics"

    def _close():
        server.shutdown()
        server.server_close()
        thread.join(timeout=1.0)

    return url, _close


def test_zero_failures_no_violation():
    payload = "decision_signature_verification_failures_total 0\n"
    url, close = _run_test_server(payload)
    try:
        m = PhaseBMonitor(url, timeout=1.0)
        r = m.check_signature_failures(threshold=0)
        assert r["failure_count"] == 0
        assert r["violation"] is False
    finally:
        close()


def test_five_failures_triggers_violation():
    payload = "decision_signature_verification_failures_total 5\n"
    url, close = _run_test_server(payload)
    try:
        m = PhaseBMonitor(url, timeout=1.0)
        r = m.check_signature_failures(threshold=2)
        assert r["failure_count"] == 5
        assert r["violation"] is True
    finally:
        close()


def test_http_timeout_raises(monkeypatch):
    # Simulate timeout by having urlopen raise socket.timeout
    def _raise_timeout(*a, **k):
        raise socket.timeout("timed out")

    monkeypatch.setattr("urllib.request.urlopen", _raise_timeout)
    m = PhaseBMonitor("http://127.0.0.1:1/metrics", timeout=0.01)
    with pytest.raises(PhaseBMonitorError):
        m.fetch_metrics()


def test_invalid_metrics_format_results_in_fetch_error():
    payload = "some_other_metric 123\n"
    url, close = _run_test_server(payload)
    try:
        m = PhaseBMonitor(url, timeout=1.0)
        with pytest.raises(PhaseBMonitorError):
            _ = m.check_signature_failures()
    finally:
        close()


def test_runtime_does_not_mutate_module_globals():
    import importlib

    mod = importlib.import_module("runtime.telemetry.phase_b_runtime")
    before = set(dir(mod))

    payload = "decision_signature_verification_failures_total 2\n"
    url, close = _run_test_server(payload)
    try:
        m = PhaseBMonitor(url, timeout=1.0)
        _ = m.check_signature_failures()
    finally:
        close()

    after = set(dir(mod))
    assert before == after


# -------------------------
# Startup invariant tests
# -------------------------


def test_verify_startup_invariants_success_case(monkeypatch):
    # Simulate presence of Phase A certification artifact
    import os

    orig_exists = os.path.exists

    def _fake_exists(path):
        if path == "PHASE_A_CERTIFICATION_VERDICT.md":
            return True
        return orig_exists(path)

    monkeypatch.setattr(os.path, "exists", _fake_exists)

    # Ensure in-cluster DNS/env var indicator is present
    monkeypatch.setenv("KUBERNETES_SERVICE_HOST", "127.0.0.1")

    payload = "decision_signature_verification_failures_total 0\n"
    url, close = _run_test_server(payload)
    try:
        m = PhaseBMonitor(url, timeout=1.0)
        inv = m.verify_startup_invariants()
        assert inv["ready"] is True
        d = inv["details"]
        assert d["certification_present"] is True
        assert d["metrics_reachable"] is True
        assert d["detector_return_is_int"] is True
        assert d["kubernetes_api_reachable"] is True
        # new fields
        assert d.get("metrics_body_contains_required") is True
    finally:
        close()


def test_missing_certification_artifact(monkeypatch):
    import os

    orig_exists = os.path.exists

    def _fake_exists(path):
        if path == "PHASE_A_CERTIFICATION_VERDICT.md":
            return False
        return orig_exists(path)

    monkeypatch.setattr(os.path, "exists", _fake_exists)
    monkeypatch.setenv("KUBERNETES_SERVICE_HOST", "127.0.0.1")

    payload = "decision_signature_verification_failures_total 0\n"
    url, close = _run_test_server(payload)
    try:
        m = PhaseBMonitor(url, timeout=1.0)
        inv = m.verify_startup_invariants()
        assert inv["ready"] is False
        assert inv["details"]["certification_present"] is False
    finally:
        close()


def test_metrics_endpoint_unreachable(monkeypatch):
    import os

    # Certification present
    orig_exists = os.path.exists

    def _fake_exists(path):
        if path == "PHASE_A_CERTIFICATION_VERDICT.md":
            return True
        return orig_exists(path)

    monkeypatch.setattr(os.path, "exists", _fake_exists)
    monkeypatch.setenv("KUBERNETES_SERVICE_HOST", "127.0.0.1")

    # Use a non-listening port to simulate unreachable metrics endpoint
    m = PhaseBMonitor("http://127.0.0.1:1/metrics", timeout=0.01)
    inv = m.verify_startup_invariants()
    assert inv["ready"] is False
    assert inv["details"]["metrics_reachable"] is False


def test_detector_returns_non_int(monkeypatch):
    import os

    # Certification present
    orig_exists = os.path.exists

    def _fake_exists(path):
        if path == "PHASE_A_CERTIFICATION_VERDICT.md":
            return True
        return orig_exists(path)

    monkeypatch.setattr(os.path, "exists", _fake_exists)
    monkeypatch.setenv("KUBERNETES_SERVICE_HOST", "127.0.0.1")

    payload = "decision_signature_verification_failures_total 2\n"
    url, close = _run_test_server(payload)
    try:
        # Force detector (the symbol used by PhaseB runtime) to return non-int
        monkeypatch.setattr(
            "runtime.telemetry.phase_b_runtime.detect_decision_signature_violations",
            lambda s: "bad-value",
            raising=True,
        )

        m = PhaseBMonitor(url, timeout=1.0)
        inv = m.verify_startup_invariants()
        assert inv["ready"] is False
        assert inv["details"]["detector_return_is_int"] is False
    finally:
        close()


def test_start_returns_degraded_when_invariants_fail(monkeypatch, capsys):
    import os
    from runtime.telemetry.phase_b_runtime import StartupState

    orig_exists = os.path.exists

    def _fake_exists(path):
        if path == "PHASE_A_CERTIFICATION_VERDICT.md":
            return False
        return orig_exists(path)

    monkeypatch.setattr(os.path, "exists", _fake_exists)
    monkeypatch.setenv("KUBERNETES_SERVICE_HOST", "127.0.0.1")

    payload = "decision_signature_verification_failures_total 0\n"
    url, close = _run_test_server(payload)
    try:
        m = PhaseBMonitor(url, timeout=1.0)
        status = m.start()
        assert status == StartupState.DEGRADED
        captured = capsys.readouterr()
        assert "DEGRADED" in captured.out
    finally:
        close()
