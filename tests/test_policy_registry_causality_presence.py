from pathlib import Path

import yaml


def test_causality_observed_key_present_and_bool():
    p = Path("docs/policies/policy-registry.yaml")
    assert p.exists(), "policy-registry.yaml missing"
    reg = yaml.safe_load(p.read_text())
    for policy in reg.get("policies", []):
        assert "causality_observed" in policy, f"Policy {policy.get('name')} missing 'causality_observed' key"
        assert isinstance(
            policy.get("causality_observed"), bool
        ), f"Policy {policy.get('name')}: 'causality_observed' must be boolean"
