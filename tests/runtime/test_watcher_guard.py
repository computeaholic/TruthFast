"""Guard tests to ensure watcher is signal-only and cannot promote authority."""

from __future__ import annotations

import inspect

import pytest

import runtime.spire.watcher as watcher
from runtime.authority.state import AuthorityState, get_state
from runtime.signal.fabric import subscribe

pytestmark = pytest.mark.unit


def test_watcher_module_does_not_import_authority_setters():
    src = inspect.getsource(watcher)
    # Static check: watcher source must not reference set_state or AuthorityState
    assert "set_state" not in src
    assert "AuthorityState" not in src


def test_watcher_events_do_not_change_authority(tmp_path):
    # Ensure deterministic starting state (avoid interference from other tests)
    from runtime.authority.state import set_state

    set_state(AuthorityState.UNCLAIMED, reason="test-setup")
    assert get_state() in (AuthorityState.UNCLAIMED, None)

    events: list[dict] = []

    def _h(e: dict):
        events.append(e)

    subscribe("SPIRE_SOCKET_AVAILABLE", _h)
    subscribe("SPIRE_SOCKET_LOST", _h)

    sock = str(tmp_path / "workload.sock")
    w = watcher.SpireWatcher(sock, poll_interval=0.01)
    try:
        # simulate socket appear
        open(sock, "a").close()
        w._check_once()
        # authority should not have changed
        assert get_state() in (AuthorityState.UNCLAIMED, None)
        # simulate socket disappear
        import os

        os.remove(sock)
        w._check_once()
        assert get_state() in (AuthorityState.UNCLAIMED, None)
    finally:
        w.stop()
