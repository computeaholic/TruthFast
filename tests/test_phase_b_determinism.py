from runtime.telemetry.phase_b_monitor import detect_decision_signature_violations
from runtime.telemetry.phase_b_runtime import PhaseBMonitor


def test_detector_is_deterministic_same_input_same_output():
    payload = 'decision_signature_verification_failures_total{reason="x"} 4\n'
    a = detect_decision_signature_violations(payload)
    b = detect_decision_signature_violations(payload)
    assert a == b


def test_verify_startup_invariants_deterministic(monkeypatch):
    # Stable environment: cert present, kube env var set, metrics server returns same payload
    import os

    orig_exists = os.path.exists

    def _fake_exists(path):
        if path == "PHASE_A_CERTIFICATION_VERDICT.md":
            return True
        return orig_exists(path)

    monkeypatch.setattr(os.path, "exists", _fake_exists)
    monkeypatch.setenv("KUBERNETES_SERVICE_HOST", "127.0.0.1")

    # simple metrics payload
    payload = "decision_signature_verification_failures_total 0\n"

    # use the same test server helper as other tests
    from tests.test_phase_b_runtime import _run_test_server

    url, close = _run_test_server(payload)
    try:
        m = PhaseBMonitor(url, timeout=1.0)
        first = m.verify_startup_invariants()
        second = m.verify_startup_invariants()
        assert first == second
    finally:
        close()


def test_start_stable_across_runs(monkeypatch, capsys):
    import os

    orig_exists = os.path.exists

    def _fake_exists(path):
        if path == "PHASE_A_CERTIFICATION_VERDICT.md":
            return False
        return orig_exists(path)

    monkeypatch.setattr(os.path, "exists", _fake_exists)
    monkeypatch.setenv("KUBERNETES_SERVICE_HOST", "127.0.0.1")

    payload = "decision_signature_verification_failures_total 0\n"
    from tests.test_phase_b_runtime import _run_test_server

    url, close = _run_test_server(payload)
    try:
        m = PhaseBMonitor(url, timeout=1.0)
        from runtime.telemetry.phase_b_runtime import StartupState

        s1 = m.start()
        s2 = m.start()
        assert s1 == s2
        assert s1 == StartupState.DEGRADED
        captured = capsys.readouterr()
        assert "DEGRADED" in captured.out
    finally:
        close()


def test_failure_states_stable(monkeypatch):
    # Missing cert + unreachable metrics -> repeated calls stay the same
    import os

    orig_exists = os.path.exists

    def _fake_exists(path):
        if path == "PHASE_A_CERTIFICATION_VERDICT.md":
            return False
        return orig_exists(path)

    monkeypatch.setattr(os.path, "exists", _fake_exists)
    monkeypatch.delenv("KUBERNETES_SERVICE_HOST", raising=False)

    m = PhaseBMonitor("http://127.0.0.1:1/metrics", timeout=0.01)
    a = m.verify_startup_invariants()
    b = m.verify_startup_invariants()
    assert a == b


def test_no_randomness_no_global_counters():
    # Repeated detector calls should not create module-level state
    import importlib

    mod = importlib.import_module("runtime.telemetry.phase_b_monitor")
    before = set(dir(mod))
    payload = "decision_signature_verification_failures_total 7\n"
    for _ in range(5):
        assert detect_decision_signature_violations(payload) == 7
    after = set(dir(mod))
    assert before == after
