from pathlib import Path

import yaml


def test_registry_counterfactuals_present_each_policy():
    p = Path("docs/policies/policy-registry.yaml")
    assert p.exists(), "policy-registry.yaml missing"
    reg = yaml.safe_load(p.read_text())
    for policy in reg.get("policies", []):
        assert "counterfactuals" in policy, f"Policy {policy.get('name')} missing 'counterfactuals' key"
        # Explicit empty list allowed
        assert isinstance(
            policy.get("counterfactuals"), list
        ), f"Policy {policy.get('name')}: 'counterfactuals' must be a list"
