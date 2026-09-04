#!/usr/bin/env python3
import json
import pathlib
import sys
from typing import Any


PHASE_ORDER = [
    "cluster-reset",
    "api-readiness",
    "crd-establishment",
    "istio-base-install",
    "istiod-rollout",
    "sidecar-injector-readiness",
    "spire-server-readiness",
    "spire-agent-rollout",
    "spire-csr-install",
    "spire-reconciliation",
    "ingress-gateway-rollout",
    "observability-rollout",
    "loki-readiness",
    "proof-start",
]


def load_events(path: pathlib.Path) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    if not path.exists():
        return events
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return events


def latest_by_phase(events: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    latest: dict[str, dict[str, Any]] = {}
    for event in events:
        phase = event.get("phase")
        if not phase:
            continue
        latest[phase] = event
    return latest


def normalize_phase_row(phase: str, event: dict[str, Any] | None) -> dict[str, Any]:
    if not event:
        return {
            "phase": phase,
            "status": "MISSING",
            "start_timestamp": "",
            "end_timestamp": "",
            "duration_seconds": 0,
            "retry_count": 0,
            "first_failure_line": "",
            "last_progress_marker": "",
        }

    row = {
        "phase": phase,
        "status": event.get("status", "UNKNOWN"),
        "start_timestamp": event.get("start_timestamp", ""),
        "end_timestamp": event.get("end_timestamp", ""),
        "duration_seconds": int(event.get("duration_seconds", 0) or 0),
        "retry_count": int(event.get("retry_count", 0) or 0),
        "first_failure_line": event.get("first_failure_line", "") or "",
        "last_progress_marker": event.get("last_progress_marker", "") or "",
    }
    return row


def write_json(path: pathlib.Path, rows: list[dict[str, Any]]) -> None:
    payload = {
        "phase_count": len(rows),
        "phases": rows,
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def md_escape(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ").strip()


def write_markdown(path: pathlib.Path, rows: list[dict[str, Any]]) -> None:
    lines = [
        "# Bootstrap Phase Matrix",
        "",
        "| Phase | Status | Start | End | Duration (s) | Retries | First Failure Line | Last Progress Marker |",
        "| --- | --- | --- | --- | ---: | ---: | --- | --- |",
    ]

    for row in rows:
        lines.append(
            (
                "| {phase} | {status} | {start} | {end} | {duration} | "
                "{retries} | {first_failure} | {last_marker} |"
            ).format(
                phase=md_escape(row["phase"]),
                status=md_escape(row["status"]),
                start=md_escape(row["start_timestamp"]),
                end=md_escape(row["end_timestamp"]),
                duration=row["duration_seconds"],
                retries=row["retry_count"],
                first_failure=md_escape(row["first_failure_line"]),
                last_marker=md_escape(row["last_progress_marker"]),
            )
        )

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: render_bootstrap_timeline.py "
            "<events.jsonl> <bootstrap_timeline.json> <bootstrap_phase_matrix.md>"
        )
        return 2

    events_path = pathlib.Path(sys.argv[1])
    json_path = pathlib.Path(sys.argv[2])
    md_path = pathlib.Path(sys.argv[3])

    events = load_events(events_path)
    latest = latest_by_phase(events)
    rows = [normalize_phase_row(phase, latest.get(phase)) for phase in PHASE_ORDER]

    json_path.parent.mkdir(parents=True, exist_ok=True)
    md_path.parent.mkdir(parents=True, exist_ok=True)

    write_json(json_path, rows)
    write_markdown(md_path, rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
