from pathlib import Path

import yaml


def test_policy_reason_rule_exists_and_structure():
    rules_file = Path("platform/deploy/infra/prometheus/rules/policy-recording-rules.yaml")
    assert rules_file.exists(), "policy recording rules file missing"
    rules = yaml.safe_load(rules_file.read_text())
    policy_group = next((g for g in rules.get("groups", []) if g.get("name") == "policy"), None)
    assert policy_group is not None

    reason_rule = next(
        (r for r in policy_group.get("rules", []) if r.get("record") == "policy_reason_code:storage_latency"), None
    )
    assert reason_rule is not None, "Missing policy_reason_code:storage_latency rule"

    expr = reason_rule.get("expr", "")
    # Must include absent(...) to handle missing inputs
    assert "absent(" in expr, "Missing absent(...) clause; missing input may not resolve to code 0"
    # Must map to * 0, * 1, * 2 in branches
    assert "* 0" in expr or "*0" in expr, "Missing branch that assigns 0 for missing input"
    assert "* 1" in expr or "*1" in expr, "Missing branch that assigns 1 for threshold-exceeded"
    assert "* 2" in expr or "*2" in expr, "Missing branch that assigns 2 for allow"


def test_policy_reason_convenience_rule_and_label():
    rules_file = Path("platform/deploy/infra/prometheus/rules/policy-recording-rules.yaml")
    rules = yaml.safe_load(rules_file.read_text())
    policy_group = next((g for g in rules.get("groups", []) if g.get("name") == "policy"), None)
    assert isinstance(policy_group, dict)

    conv = next((r for r in policy_group.get("rules", []) if r.get("record") == "policy_reason_code"), None)
    assert conv is not None, "Missing convenience rule 'policy_reason_code'"
    labels = conv.get("labels", {})
    assert labels.get("policy") == "storage_latency", "Convenience rule must set policy=storage_latency"


def test_policy_reason_panel_exists():
    path = Path("platform/deploy/infra/grafana/dashboards/storage-health.json")
    assert path.exists(), "storage-health.json missing"
    import json

    doc = json.loads(path.read_text())
    panels = doc.get("panels", [])
    panel = next((p for p in panels if p.get("title") == "Policy Reason: Storage Latency"), None)
    assert panel is not None, "Policy Reason panel not found"
    exprs = [t.get("expr", "") for t in panel.get("targets", [])]
    exprs_normalized = [e.replace('\\"', '"') for e in exprs]
    assert (
        'policy_reason_code{policy="storage_latency"}' in exprs_normalized
    ), 'Panel must query policy_reason_code{policy="storage_latency"}'
    desc = panel.get("description", "")
    assert "POLICY" not in desc or "CODES" in desc, "Panel description must include CODES explanation"
