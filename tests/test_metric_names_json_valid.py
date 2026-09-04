from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit


def test_metric_names_json_is_valid_and_sane() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    path = repo_root / "artifacts/config/metric_names.json"
    assert path.exists(), "Expected artifacts/config/metric_names.json at repo root"

    data = json.loads(path.read_text(encoding="utf-8"))
    assert isinstance(data, dict), f"Expected JSON object, got {type(data).__name__}"

    assert data.get("status") == "success", "Expected status == 'success'"

    metrics = data.get("data")
    assert isinstance(metrics, list), f"Expected data list, got {type(metrics).__name__}"
    assert metrics, "Expected at least one metric name"

    bad: list[str] = []
    for idx, metric in enumerate(metrics):
        if not isinstance(metric, str):
            bad.append(f"data[{idx}]: expected str, got {type(metric).__name__}")
            continue
        if not metric.strip():
            bad.append(f"data[{idx}]: empty/whitespace-only metric name")
            continue
        if metric != metric.strip():
            bad.append(f"data[{idx}]: leading/trailing whitespace: {metric!r}")
            continue

    counts = Counter(m for m in metrics if isinstance(m, str))
    dups = [m for m, c in counts.items() if c > 1]
    if dups:
        bad.append(f"duplicate metric names found (showing up to 20): {dups[:20]!r}")

    assert not bad, "\n".join(bad)
