from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.integration

REPO_ROOT = Path(__file__).resolve().parents[1]
CLASSIFY_DRIFT = REPO_ROOT / "scripts" / "debug" / "classify_drift.sh"
CLASSIFICATION_PATH = REPO_ROOT / "artifacts" / "runtime" / "runtime_drift_classification.json"


def test_agent_lab_runtime_digests_are_admissible_projections() -> None:
    result = subprocess.run(
        ["bash", str(CLASSIFY_DRIFT)],
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    payload = json.loads(CLASSIFICATION_PATH.read_text(encoding="utf-8"))

    entries = [entry for entry in payload.get("entries", []) if isinstance(entry, dict)]
    targets = {"attacker-agent", "research-agent", "writer-agent", "rogue-agent"}
    for app in targets:
        entry = next(
            (
                item
                for item in entries
                if item.get("namespace") == "agents-lab"
                and item.get("container_name") == app
                and str(item.get("pod") or "").startswith(app + "-")
            ),
            None,
        )
        assert entry is not None, f"missing runtime drift entry for {app}"
        assert entry.get("resolution_kind") in {"exact_digest", "manifest_projection"}
        assert entry.get("is_internal") is True
        assert entry.get("is_signed") is True
        assert entry.get("resolution_kind") != "unexplained_runtime_digest"

    assert not payload.get("external_images"), "admissible agent digests were misclassified as external"
    assert not payload.get("unsigned_images"), "admissible agent digests were misclassified as unsigned"
    assert not payload.get("unexplained"), "admissible agent digests were misclassified as unexplained"
