import json
from pathlib import Path

import yaml


def load_registry() -> dict:
    p = Path("docs/policies/policy-registry.yaml")
    assert p.exists(), "policy-registry.yaml missing"
    return yaml.safe_load(p.read_text())


def load_policy_rules() -> set:
    rules_file = Path("platform/deploy/infra/prometheus/rules/policy-recording-rules.yaml")
    assert rules_file.exists(), "policy recording rules file missing"
    rules = yaml.safe_load(rules_file.read_text())
    policy_group = next((g for g in rules.get("groups", []) if g.get("name") == "policy"), None)
    assert policy_group is not None, "No 'policy' group found in recording rules"

    policies = set()
    for r in policy_group.get("rules", []):
        rec = r.get("record", "")
        if rec == "policy_decision":
            lab = r.get("labels", {}).get("policy")
            if lab:
                policies.add(lab)
        elif rec.startswith("policy_decision:"):
            policies.add(rec.split("policy_decision:", 1)[1])
    return policies


def test_registry_entries_have_rules_and_rules_have_registry_entries():
    registry = load_registry()
    reg_policies = {p["name"] for p in registry.get("policies", [])}

    rule_policies = load_policy_rules()

    # Any rule without registry entry -> fail
    missing_registry = [r for r in rule_policies if r not in reg_policies]
    assert not missing_registry, f"Policy recording rules exist without registry entries: {missing_registry}"

    # Any registry entry without rule -> fail
    missing_rules = [p for p in reg_policies if p not in rule_policies]
    assert not missing_rules, f"Registry contains policies without recording rules: {missing_rules}"


def test_posture_included_policies_are_covered_by_posture():
    registry = load_registry()
    policies_to_include = {p["name"] for p in registry.get("policies", []) if p.get("posture_included")}
    assert policies_to_include, "No policies marked posture_included: true in registry"

    rules = yaml.safe_load(Path("platform/deploy/infra/prometheus/rules/policy-recording-rules.yaml").read_text())
    policy_group = next((g for g in rules.get("groups", []) if g.get("name") == "policy"), None)
    assert isinstance(policy_group, dict)
    posture_rule = next((r for r in policy_group.get("rules", []) if r.get("record") == "policy_posture"), None)
    assert posture_rule is not None, "policy_posture rule missing"
    expr = posture_rule.get("expr", "")
    assert "min(policy_decision" in expr, "policy_posture must aggregate policy_decision via min()"

    # Ensure each posture_included policy has a decision rule (thus included by regex)
    rule_policies = load_policy_rules()
    missing = [p for p in policies_to_include if p not in rule_policies]
    assert not missing, f"Policies marked posture_included but missing decision rules: {missing}"


def test_policy_overview_dashboard_references_registry():
    registry = load_registry()
    reg_policies = {p["name"] for p in registry.get("policies", [])}

    path = Path("platform/deploy/infra/grafana/dashboards/policy-overview.json")
    assert path.exists(), "policy-overview.json missing"
    doc = json.loads(path.read_text())

    # Dashboard-level annotation
    desc = doc.get("description", "")
    assert (
        "POLICY_REGISTRY: docs/policies/policy-registry.yaml" in desc
    ), "Dashboard POLICY_REGISTRY annotation missing or incorrect"

    panels = doc.get("panels", [])
    panel_titles = {p.get("title") for p in panels}

    # Any panel referencing a policy not in registry -> fail
    allowed_non_policy_panels = {
        "System Policy Posture",
        "Authority Verification Failures",
        "Policy Posture vs Operator Actions",
        "PEP Would Enforce (Count/Last)",
    }
    dangling = [t for t in panel_titles if t not in reg_policies and t not in allowed_non_policy_panels]
    assert not dangling, f"Dashboard panels reference policies not present in registry: {dangling}"

    # Each registry policy must have a panel
    missing_panel = [p for p in reg_policies if p not in panel_titles]
    assert not missing_panel, f"Registry policies missing from dashboard panels: {missing_panel}"
