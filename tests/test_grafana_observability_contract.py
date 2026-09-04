from __future__ import annotations

import json
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def _extract_embedded_json(manifest: str, marker: str) -> dict:
    lines = manifest.splitlines()
    start = None
    for index, line in enumerate(lines):
        if line.strip() == f"{marker}: |":
            start = index + 1
            break
    if start is None:
        raise AssertionError(f"missing embedded JSON block for {marker}")

    block: list[str] = []
    for line in lines[start:]:
        if line.startswith("---"):
            break
        if line.startswith("    "):
            block.append(line[4:])
            continue
        if line.strip() == "" and block:
            block.append("")
            continue
        if block:
            break

    return json.loads("\n".join(block))


def test_observability_grafana_base_contract_exposes_review_datasources() -> None:
    manifest = _read("platform/deploy/infra/observability/base/grafana.yaml")

    assert "uid: prometheus" in manifest
    assert "uid: loki" in manifest
    assert "uid: tempo" in manifest
    assert "http://loki:3100" in manifest
    assert "http://tempo:3100" in manifest
    assert "threadforge-grafana-dashboard-providers" in manifest
    assert "mountPath: /var/lib/grafana/dashboards/threadforge" in manifest
    assert "mountPath: /etc/grafana/provisioning/dashboards" in manifest

    dashboard = _extract_embedded_json(manifest, "trust-root-lifecycle.json")
    templating = dashboard.get("templating", {}).get("list", [])
    assert any(item.get("name") == "prom_ds" for item in templating)

    service_traffic = _extract_embedded_json(manifest, "service-traffic.json")
    assert service_traffic["title"] == "ThreadForge — Service Traffic & Signals"
    panel_titles = {panel["title"] for panel in service_traffic["panels"]}
    assert "Loki Up" in panel_titles
    assert "Tempo Up" in panel_titles
    assert "Recent Logs — All Namespaces" in panel_titles
    assert "Recent Traces — Tempo" in panel_titles
    traffic_templating = service_traffic.get("templating", {}).get("list", [])
    assert {item.get("name") for item in traffic_templating} >= {"prom_ds", "loki_ds", "tempo_ds"}


def test_observability_grafana_gitops_contract_exposes_review_datasources() -> None:
    manifest = _read("platform/deploy/gitops/infra/observability/grafana.yaml")

    assert "uid: prometheus" in manifest
    assert "uid: loki" in manifest
    assert "uid: tempo" in manifest
    assert "http://loki.loki.svc.cluster.local:3100" in manifest
    assert "http://tempo.tempo.svc.cluster.local:3100" in manifest
    assert "grafana-dashboard-providers" in manifest
    assert "mountPath: /var/lib/grafana/dashboards/threadforge" in manifest
    assert "mountPath: /etc/grafana/provisioning/dashboards" in manifest

    dashboard = _extract_embedded_json(manifest, "trust-root-lifecycle.json")
    templating = dashboard.get("templating", {}).get("list", [])
    assert any(item.get("name") == "prom_ds" for item in templating)
