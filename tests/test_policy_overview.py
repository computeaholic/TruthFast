import json
from pathlib import Path

import yaml


def load_policy_names_from_rules() -> set:
    rules_file = Path("platform/deploy/infra/prometheus/rules/policy-recording-rules.yaml")
    assert rules_file.exists(), "policy recording rules file missing"
    rules = yaml.safe_load(rules_file.read_text())
    groups = rules.get("groups", [])
    policy_group = next((g for g in groups if g.get("name") == "policy"), None)
    assert policy_group is not None, "No 'policy' group found in recording rules"

    policies = set()
    for r in policy_group.get("rules", []):
        rec = r.get("record", "")
        # Convenience rule with label: policy_decision + labels.policy
        if rec == "policy_decision":
            labels = r.get("labels", {})
            p = labels.get("policy")
            if p:
                policies.add(p)
        # Or derive from record name like policy_decision:storage_latency
        elif rec.startswith("policy_decision:"):
            policies.add(rec.split("policy_decision:", 1)[1])
    return policies


def test_policy_overview_dashboard_and_annotation():
    path = Path("platform/deploy/infra/grafana/dashboards/policy-overview.json")
    assert path.exists(), "policy-overview.json missing"

    doc = json.loads(path.read_text())
    desc = doc.get("description", "")
    assert "OPERATIONAL_POLICY_INVENTORY:" in desc, "Dashboard annotation missing OPERATIONAL_POLICY_INVENTORY"
    assert "SOURCE: Prometheus recording rules" in desc, "Dashboard annotation must state source"
    assert "ABSENCE: DENY" in desc, "Dashboard annotation must state absence behavior"


def test_panels_cover_all_policies_and_match_queries():
    policies = load_policy_names_from_rules()
    assert policies, "No policies found in recording rules"

    path = Path("platform/deploy/infra/grafana/dashboards/policy-overview.json")
    doc = json.loads(path.read_text())
    panels = doc.get("panels", [])

    panel_titles = {p.get("title") for p in panels}

    # Ensure each policy from rules has a panel with the same title
    missing = [p for p in policies if p not in panel_titles]
    assert not missing, f"Policies missing from dashboard panels: {missing}"

    # Validate each panel's query references policy_decision{policy="<name>"}
    for p in panels:
        title = p.get("title")
        # Only validate per-policy panels (skip global/aux panels)
        if title not in policies:
            continue
        targets = p.get("targets", [])
        assert targets, f"Panel {title} has no targets"
        exprs = [t.get("expr", "") for t in targets]
        expected = f'policy_decision{{policy="{title}"}}'
        assert expected in exprs, f"Panel {title} must query {expected}"

    # Ensure no panel references a *policy-like* title that has no recording rule
    policy_like = [t for t in panel_titles if t and t == t.lower() and " " not in t]
    missing_panel_policies = [t for t in policy_like if t not in policies]
    assert not missing_panel_policies, f"Panels reference unknown policies: {missing_panel_policies}"
