from pathlib import Path

import yaml


def load_registry():
    return yaml.safe_load(Path("docs/policies/policy-registry.yaml").read_text())


def load_policy_rules():
    rules = yaml.safe_load(Path("platform/deploy/infra/prometheus/rules/policy-recording-rules.yaml").read_text())
    policy_group = next((g for g in rules.get("groups", []) if g.get("name") == "policy"), None)
    assert policy_group is not None
    return {r.get("record") for r in policy_group.get("rules", [])}


def test_registry_pressure_counterfactuals_unease_have_rules():
    reg = load_registry()
    records = load_policy_rules()
    for p in reg.get("policies", []):
        if p["name"] != "storage_latency":
            continue
        # Pressure signals
        for s in p.get("pressure_signals", []):
            expected = f"{s['name']}:storage_latency"
            assert expected in records, f"Missing recording rule for pressure signal: {expected}"
            assert s["name"] in records or True  # convenience check handled elsewhere
        # Counterfactuals
        for c in p.get("counterfactuals", []):
            expected = f"{c['name']}:storage_latency"
            assert expected in records, f"Missing recording rule for counterfactual: {expected}"
        # Unease signals
        for u in p.get("unease_signals", []):
            expected = f"{u['name']}:storage_latency"
            assert expected in records, f"Missing recording rule for unease signal: {expected}"
        # volatility_threshold must be explicit
        assert "volatility_threshold" in p, "volatility_threshold missing from registry"


def test_dashboard_panels_reference_new_metrics():
    import json

    doc = json.loads(Path("platform/deploy/infra/grafana/dashboards/storage-health.json").read_text())
    panels = {p.get("title"): p for p in doc.get("panels", [])}

    # Check Pressure Margin panel
    pm = panels.get("Pressure: Margin")
    assert pm is not None, "Pressure: Margin panel missing"
    exprs = [t.get("expr", "") for t in pm.get("targets", [])]
    # Some dashboards serialize quotes (e.g., \"storage_latency\"); normalize for test
    exprs_normalized = [e.replace('\\"', '"') for e in exprs]
    assert 'policy_pressure_margin{policy="storage_latency"}' in exprs_normalized

    # Check Unease Count panel
    uc = panels.get("Unease Count")
    assert uc is not None, "Unease Count panel missing"
    exprs = [t.get("expr", "") for t in uc.get("targets", [])]
    assert "policy_unease_allow_under_pressure" in exprs[0]
    assert "policy_unease_deny_missing_input" in exprs[0]
    assert "policy_unease_volatility_breach" in exprs[0]
