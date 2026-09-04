from pathlib import Path

import yaml


def load_rules(path: Path):
    with open(path) as f:
        return yaml.safe_load(f)


def test_policy_recording_rules_exist():
    rules_file = Path("platform/deploy/infra/prometheus/rules/policy-recording-rules.yaml")
    assert rules_file.exists(), "policy recording rules file missing"

    rules = load_rules(rules_file)
    assert isinstance(rules, dict)
    groups = rules.get("groups", [])

    # Find the 'policy' group
    policy_group = None
    for g in groups:
        if g.get("name") == "policy":
            policy_group = g
            break
    assert policy_group is not None, "No 'policy' group found in recording rules"

    rule_records = [r.get("record") for r in policy_group.get("rules", [])]
    assert "policy_decision:storage_latency" in rule_records, "Missing rule 'policy_decision:storage_latency'"
    assert "policy_decision" in rule_records, "Missing convenience rule 'policy_decision'"


def test_storage_latency_rule_expr_and_absent_clause():
    rules_file = Path("platform/deploy/infra/prometheus/rules/policy-recording-rules.yaml")
    rules = load_rules(rules_file)
    groups = rules.get("groups", [])

    policy_group = next((g for g in groups if g.get("name") == "policy"), None)
    assert policy_group is not None

    # Find the specific rule
    storage_rule = next(
        (r for r in policy_group.get("rules", []) if r.get("record") == "policy_decision:storage_latency"), None
    )
    assert storage_rule is not None

    expr = storage_rule.get("expr", "")
    # Must reference 0.95 quantile and probe_duration_seconds_bucket
    assert "histogram_quantile(0.95" in expr.replace("\n", " "), "p95 histogram_quantile not found in expr"
    assert "probe_duration_seconds_bucket" in expr, "probe_duration_seconds_bucket not referenced in expr"
    assert "< 0.25" in expr or "<0.25" in expr, "threshold comparison '< 0.25' missing"
    # Must include absent clause to ensure missing inputs yield DENY
    assert "absent(" in expr, "absent(...) clause missing; missing input may not yield DENY"


def test_convenience_rule_exports_policy_label():
    rules_file = Path("platform/deploy/infra/prometheus/rules/policy-recording-rules.yaml")
    rules = load_rules(rules_file)
    groups = rules.get("groups", [])

    policy_group = next((g for g in groups if g.get("name") == "policy"), None)
    assert policy_group is not None

    conv_rule = next((r for r in policy_group.get("rules", []) if r.get("record") == "policy_decision"), None)
    assert conv_rule is not None, "Missing convenience recording rule 'policy_decision'"

    labels = conv_rule.get("labels", {})
    assert labels.get("policy") == "storage_latency", "Convenience rule must add label policy=storage_latency"

    expr = conv_rule.get("expr", "")
    assert (
        "policy_decision:storage_latency" in expr
    ), "Convenience rule must reference 'policy_decision:storage_latency'"
