from pathlib import Path

import yaml


def test_unease_volatility_breach_rule_has_sample_checks_and_threshold():
    rules = yaml.safe_load(Path("platform/deploy/infra/prometheus/rules/policy-recording-rules.yaml").read_text())
    policy_group = next((g for g in rules.get("groups", []) if g.get("name") == "policy"), None)
    assert policy_group is not None

    rule = next(
        (
            r
            for r in policy_group.get("rules", [])
            if r.get("record") == "policy_unease_volatility_breach:storage_latency"
        ),
        None,
    )
    assert rule is not None, "volatility breach rule missing"
    expr = rule.get("expr", "")
    assert "> 0.1" in expr or ">0.1" in expr, "volatility threshold 0.1 must appear in rule"
    assert (
        "probe_duration_seconds_count" in expr
    ), "rule must check probe duration sample counts to avoid sparse-data false positives"


def test_unease_allow_under_pressure_detects_inconsistency():
    rules = yaml.safe_load(Path("platform/deploy/infra/prometheus/rules/policy-recording-rules.yaml").read_text())
    policy_group = next((g for g in rules.get("groups", []) if g.get("name") == "policy"), None)
    assert isinstance(policy_group, dict)
    rule = next(
        (
            r
            for r in policy_group.get("rules", [])
            if r.get("record") == "policy_unease_allow_under_pressure:storage_latency"
        ),
        None,
    )
    assert rule is not None, "allow_under_pressure rule missing"
    expr = rule.get("expr", "")
    assert (
        "policy_decision:storage_latency" in expr or "policy_decision:storage_latency == 1" in expr
    ), "allow_under_pressure must reference decision metric"
    assert (
        ">=" in expr or ">" in expr
    ), "allow_under_pressure must check p95 compared to threshold to detect inconsistency"
