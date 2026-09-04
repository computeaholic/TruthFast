def test_operator_action_metrics_exist():
    from runtime.telemetry.prometheus_exporter import METRICS

    assert "operator_action_active" in METRICS, "operator_action_active metric not registered"
    assert "operator_action_total" in METRICS, "operator_action_total metric not registered"


def test_trust_continuity_metrics_exist():
    from runtime.telemetry.prometheus_exporter import METRICS

    required = [
        "threadforge_trust_root_age_seconds",
        "threadforge_trust_publication_age_seconds",
        "threadforge_trust_publication_drift",
        "threadforge_trust_root_expiration_seconds",
        "threadforge_trust_reconciliation_success_total",
        "threadforge_trust_reconciliation_failure_total",
    ]
    for metric in required:
        assert metric in METRICS, f"{metric} metric not registered"
