from pathlib import Path

import yaml


def test_policy_posture_rule_exists_and_expr():
    rules_file = Path("platform/deploy/infra/prometheus/rules/policy-recording-rules.yaml")
    assert rules_file.exists(), "policy recording rules file missing"
    rules = yaml.safe_load(rules_file.read_text())
    policy_group = next((g for g in rules.get("groups", []) if g.get("name") == "policy"), None)
    assert policy_group is not None

    posture = next((r for r in policy_group.get("rules", []) if r.get("record") == "policy_posture"), None)
    assert posture is not None, "Missing policy_posture recording rule"

    expr = posture.get("expr", "")
    assert (
        "min(policy_decision" in expr or "min(policy_decision" in expr.replace(" ", "").lower()
    ), "policy_posture must aggregate policy_decision via min()"
    assert "absent(" in expr, "policy_posture must include absent(...) handling to fail closed"
    # Ensure posture aggregates across labeled policy_decision metrics (mechanical inclusion)
    assert (
        'policy=~".+"' in expr or "policy=~'.+'" in expr or 'policy=~".+"' in expr.replace(" ", "")
    ), 'policy_posture must include policy=~".+" to include all labeled policy decisions'


def test_policy_posture_dashboard_panel():
    path = Path("platform/deploy/infra/grafana/dashboards/policy-overview.json")
    assert path.exists(), "policy-overview.json missing"
    import json

    doc = json.loads(path.read_text())
    panels = doc.get("panels", [])
    panel = next((p for p in panels if p.get("title") == "System Policy Posture"), None)
    assert panel is not None, "System Policy Posture panel not found"
    exprs = [t.get("expr", "") for t in panel.get("targets", [])]
    assert "policy_posture" in exprs, "Panel must query policy_posture"
