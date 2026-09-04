from runtime.telemetry.phase_b_monitor import detect_decision_signature_violations


def test_returns_zero_when_metric_absent():
    assert detect_decision_signature_violations("") == 0
    assert detect_decision_signature_violations("# HELP some_other_metric 1\n") == 0


def test_extracts_zero_value():
    payload = "decision_signature_verification_failures_total 0"
    assert detect_decision_signature_violations(payload) == 0


def test_extracts_five_value():
    payload = "decision_signature_verification_failures_total 5"
    assert detect_decision_signature_violations(payload) == 5


def test_pure_behavior_no_mutation():
    payload = "decision_signature_verification_failures_total 3"
    original = payload[:]
    assert detect_decision_signature_violations(payload) == 3
    # confirm input unchanged (pure function)
    assert payload == original


def test_sums_multiple_labelled_samples():
    payload = """
    # HELP decision_signature_verification_failures_total failures
    # TYPE decision_signature_verification_failures_total counter
    decision_signature_verification_failures_total{reason="a"} 2
    decision_signature_verification_failures_total{reason="b"} 3
    """
    assert detect_decision_signature_violations(payload) == 5
