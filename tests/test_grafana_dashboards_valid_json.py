from __future__ import annotations

import json
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def _dashboard_json_files() -> list[Path]:
    repo_root = _repo_root()

    search_roots = [
        repo_root / "dashboards",
        repo_root / "platform" / "deploy" / "infra" / "grafana" / "dashboards",
        repo_root / "platform" / "deploy" / "infra" / "minio" / "grafana" / "dashboards",
        repo_root / "platform" / "runtime" / "telemetry" / "grafana" / "dashboards",
    ]

    files: list[Path] = []
    for root in search_roots:
        if not root.exists():
            continue
        files.extend(sorted(root.rglob("*.json")))

    # De-dupe across overlapping roots (defensive).
    seen: set[Path] = set()
    uniq: list[Path] = []
    for path in files:
        resolved = path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        uniq.append(path)
    return sorted(uniq)


def test_grafana_dashboards_json_parse_and_have_title() -> None:
    dashboard_files = _dashboard_json_files()
    assert dashboard_files, "Expected at least one Grafana dashboard JSON file"

    repo_root = _repo_root()
    failures: list[str] = []

    for path in dashboard_files:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001 - test is validating parse errors
            failures.append(f"{path.relative_to(repo_root)}: JSON parse failed: {exc}")
            continue

        if not isinstance(data, dict):
            failures.append(f"{path.relative_to(repo_root)}: expected JSON object, got {type(data).__name__}")
            continue

        title = data.get("title")
        if not isinstance(title, str) or not title.strip():
            failures.append(f"{path.relative_to(repo_root)}: missing/empty top-level 'title' field")

    assert not failures, "\n".join(failures)
