import json
from pathlib import Path


def test_policy_panel_exists_and_query():
    path = Path("platform/deploy/infra/grafana/dashboards/storage-health.json")
    assert path.exists(), "storage-health.json missing"

    doc = json.loads(path.read_text())
    panels = doc.get("panels", [])

    # Find panel by title
    panel = next((p for p in panels if p.get("title") == "Policy Decision: Storage Latency"), None)
    assert panel is not None, "Policy Decision panel not found"

    # Check query is exactly the expected expression
    targets = panel.get("targets", [])
    assert len(targets) > 0, "No targets defined for policy panel"
    exprs = [t.get("expr", "") for t in targets]
    exprs_normalized = [e.replace('\\"', '"') for e in exprs]
    assert (
        'policy_decision{policy="storage_latency"}' in exprs_normalized
    ), 'Panel query must be policy_decision{policy="storage_latency"}'

    # Check panel contract is present and contains the facts
    desc = panel.get("description", "")
    assert "PANEL_CONTRACT:" in desc, "Panel contract annotation missing"
    assert 'policy_decision{policy="storage_latency"}' in desc, "Panel contract must list the metric"
    assert "DENY" in desc, "Panel contract must state what DENY means"
