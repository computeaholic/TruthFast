from __future__ import annotations

import importlib.util
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "trust" / "collect_spire_lifecycle_state.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("collect_spire_lifecycle_state", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_prepared_before_activated_stays_authoritative() -> None:
    module = _load_module()

    events = [
        {
            "event_time": "2026-07-22T00:00:00Z",
            "event": "prepared",
            "authority_id": "authority-old",
            "slot_id": "slot-old",
            "issued_at": "2026-07-22T00:00:00Z",
            "not_before": "2026-07-21T23:59:50Z",
            "not_after": "2026-07-23T00:00:00Z",
        },
        {
            "event_time": "2026-07-22T01:00:00Z",
            "event": "activated",
            "authority_id": "authority-old",
            "slot_id": "slot-old",
            "issued_at": "2026-07-22T00:30:00Z",
            "not_before": "2026-07-22T00:29:50Z",
            "not_after": "2026-07-23T00:30:00Z",
        },
        {
            "event_time": "2026-07-22T02:00:00Z",
            "event": "prepared",
            "authority_id": "authority-new",
            "slot_id": "slot-new",
            "issued_at": "2026-07-22T01:30:00Z",
            "not_before": "2026-07-22T01:29:50Z",
            "not_after": "2026-07-24T01:30:00Z",
        },
        {
            "event_time": "2026-07-22T03:00:00Z",
            "event": "activated",
            "authority_id": "authority-new",
            "slot_id": "slot-new",
            "issued_at": "2026-07-22T02:30:00Z",
            "not_before": "2026-07-22T02:29:50Z",
            "not_after": "2026-07-24T02:30:00Z",
        },
    ]

    state = module.build_state(events)

    assert state["active"]["authority_id"] == "authority-new"
    assert state["prepared"]["authority_id"] == "authority-new"
    assert state["prepared"]["key_present"] is True
    assert state["old"][0]["authority_id"] == "authority-old"


def test_prepared_after_activated_is_still_counted() -> None:
    module = _load_module()

    events = [
        {
            "event_time": "2026-07-22T00:00:00Z",
            "event": "prepared",
            "authority_id": "authority-old",
            "slot_id": "slot-old",
            "issued_at": "2026-07-22T00:00:00Z",
            "not_before": "2026-07-21T23:59:50Z",
            "not_after": "2026-07-23T00:00:00Z",
        },
        {
            "event_time": "2026-07-22T01:00:00Z",
            "event": "activated",
            "authority_id": "authority-old",
            "slot_id": "slot-old",
            "issued_at": "2026-07-22T00:30:00Z",
            "not_before": "2026-07-22T00:29:50Z",
            "not_after": "2026-07-23T00:30:00Z",
        },
        {
            "event_time": "2026-07-22T02:00:00Z",
            "event": "activated",
            "authority_id": "authority-old",
            "slot_id": "slot-old",
            "issued_at": "2026-07-22T01:30:00Z",
            "not_before": "2026-07-22T01:29:50Z",
            "not_after": "2026-07-23T01:30:00Z",
        },
        {
            "event_time": "2026-07-22T03:00:00Z",
            "event": "prepared",
            "authority_id": "authority-new",
            "slot_id": "slot-new",
            "issued_at": "2026-07-22T02:30:00Z",
            "not_before": "2026-07-22T02:29:50Z",
            "not_after": "2026-07-24T02:30:00Z",
        },
    ]

    state = module.build_state(events)

    assert state["active"]["authority_id"] == "authority-old"
    assert state["prepared"]["authority_id"] == "authority-new"
    assert state["prepared"]["key_present"] is True
    assert state["old"] == []
