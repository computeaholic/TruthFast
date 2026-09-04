#!/usr/bin/env python3
"""Collect SPIRE X.509 authority lifecycle state from SPIRE server logs.

This is an observe-only bridge for environments where the LocalAuthority API is
not yet wired into ThreadForge. It derives current ACTIVE and PREPARED authority
state from SPIRE's own CA manager lifecycle events.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path


EVENT_RE = re.compile(
    r'time="(?P<time>[^"]+)".*msg="X509 CA (?P<event>prepared|activated)" '
    r'expiration="(?P<expiration>[^"]+)" issued_at="(?P<issued_at>[^"]+)" '
    r'local_authority_id=(?P<authority_id>\S+).*slot=(?P<slot>\S+)'
)


def parse_spire_time(value: str) -> datetime:
    primary = value.split(" +0000 UTC", 1)[0]
    if "." in primary:
        prefix, fraction = primary.split(".", 1)
        primary = f"{prefix}.{fraction[:6]}"
    for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(primary, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    raise ValueError(f"unable to parse SPIRE timestamp: {value}")


def iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_iso(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def parse_events(text: str) -> list[dict]:
    events = []
    for line in text.splitlines():
        match = EVENT_RE.search(line)
        if not match:
            continue
        issued_at = parse_spire_time(match.group("issued_at"))
        expiration = parse_spire_time(match.group("expiration"))
        events.append(
            {
                "event_time": match.group("time"),
                "event": match.group("event"),
                "authority_id": match.group("authority_id"),
                "slot_id": match.group("slot"),
                "issued_at": iso(issued_at),
                "not_before": iso(issued_at - timedelta(seconds=10)),
                "not_after": iso(expiration),
            }
        )
    return events


def build_state(events: list[dict]) -> dict:
    active_event = next((event for event in reversed(events) if event["event"] == "activated"), None)
    # The prepared authority is the most recent PREPARED event, regardless of
    # whether it was logged before or after the latest ACTIVATED event. SPIRE's
    # CA-manager logs do not guarantee that prepared/activated emission order
    # matches our current bundle snapshot order, so the projection must not
    # infer successor identity from that ordering.
    prepared_event = next((event for event in reversed(events) if event["event"] == "prepared"), None)

    active = None
    if active_event is not None:
        active = {
            "state": "ACTIVE",
            "authority_id": active_event["authority_id"],
            "not_before": active_event["not_before"],
            "not_after": active_event["not_after"],
        }

    prepared = None
    if prepared_event is not None:
        prepared = {
            "state": "PREPARED",
            "authority_id": prepared_event["authority_id"],
            "not_before": prepared_event["not_before"],
            "not_after": prepared_event["not_after"],
            "key_present": True,
        }

    old = []
    active_authority_id = active_event["authority_id"] if active_event else ""
    prepared_authority_id = prepared_event["authority_id"] if prepared_event else ""
    seen_old = set()
    for event in events:
        if event["event"] != "activated":
            continue
        authority_id = event["authority_id"]
        if authority_id in {active_authority_id, prepared_authority_id} or authority_id in seen_old:
            continue
        seen_old.add(authority_id)
        old.append(
            {
                "state": "OLD",
                "authority_id": authority_id,
                "not_before": event["not_before"],
                "not_after": event["not_after"],
            }
        )

    return {
        "source": "spire-server-ca-manager-logs",
        "active": active,
        "prepared": prepared,
        "old": old,
        "observed_events": events,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--logs-file", required=True)
    parser.add_argument("--out-json", required=True)
    args = parser.parse_args(argv)

    events = parse_events(Path(args.logs_file).read_text(encoding="utf-8"))
    state = build_state(events)
    out = Path(args.out_json)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
