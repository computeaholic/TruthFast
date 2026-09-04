import importlib

from runtime.telemetry import prometheus_exporter as pe


def test_update_make_audit_metrics_and_doctor_mode():
    # Ensure registry initialized and helpers exist
    importlib.reload(pe)

    # Update with sample counts
    pe.update_make_audit_metrics(ungated_count=0, domain_counts={"operator_infra": 5, "confirm_gated": 2})

    # Validate ungated count
    ungated = float(pe.METRICS["make_ungated_mutation_targets_total"]._value.get())
    assert ungated == 0.0

    # Validate domain counts
    opinf = float(pe.METRICS["make_authority_domain_count"].labels(domain="operator_infra")._value.get())
    assert opinf == 5.0
    confirm = float(pe.METRICS["make_authority_domain_count"].labels(domain="confirm_gated")._value.get())
    assert confirm == 2.0

    # Doctor authority mode toggles
    pe.set_doctor_authority_mode(True)
    assert float(pe.METRICS["doctor_authority_mode"]._value.get()) == 1.0
    pe.set_doctor_authority_mode(False)
    assert float(pe.METRICS["doctor_authority_mode"]._value.get()) == 0.0
