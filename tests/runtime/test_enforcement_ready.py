"""Tests for attestation-driven enforcement readiness."""

from __future__ import annotations

import json
import os
import subprocess
import sys

import pytest

from runtime.attestation.manager import process_attestation_result
from runtime.metrics.enforcement import get_enforcement_ready
from runtime.spire.watcher import SpireWatcher

pytestmark = pytest.mark.unit


def test_attestation_pass_enables_enforcement_and_fail_disables(tmp_path, monkeypatch):
    # Use a hermetic state file for this test and ensure a clean starting state
    monkeypatch.setenv("THREADFORGE_ENFORCEMENT_STATE_FILE", str(tmp_path / "enforcement.json"))

    # Start disabled
    process_attestation_result("fail")
    st = get_enforcement_ready()
    assert st["enabled"] is False

    # Attestation pass (full) enables enforcement
    process_attestation_result("pass", trust_tier="full")
    st = get_enforcement_ready()
    assert st["enabled"] is True
    assert st["tier"] == "full"

    # Attestation fail disables enforcement
    process_attestation_result("fail")
    st2 = get_enforcement_ready()
    assert st2["enabled"] is False
    assert st2["tier"] == "none"


def test_spire_presence_does_not_affect_enforcement_ready(tmp_path, monkeypatch):
    # Use a hermetic state file and ensure enforcement is off
    monkeypatch.setenv("THREADFORGE_ENFORCEMENT_STATE_FILE", str(tmp_path / "enforcement.json"))
    process_attestation_result("fail")
    st = get_enforcement_ready()
    assert st["enabled"] is False

    sock_path = str(tmp_path / "workload.sock")
    watcher = SpireWatcher(sock_path, poll_interval=0.01)
    try:
        # create the socket file (simulate socket presence)
        open(sock_path, "a").close()
        watcher._check_once()
        # enforcement must remain unchanged
        st2 = get_enforcement_ready()
        assert st2["enabled"] is False
    finally:
        watcher.stop()


def test_persistence_cross_process(tmp_path, monkeypatch):
    # Verify operator/CLI visibility across processes via enforcement_status.py
    state_file = str(tmp_path / "enforcement_cross.json")
    monkeypatch.setenv("THREADFORGE_ENFORCEMENT_STATE_FILE", state_file)

    # Set enforcement in-process
    process_attestation_result("pass", trust_tier="full")

    # Call enforcement_status.py in a separate Python process and assert it sees the same state
    env = os.environ.copy()
    env["THREADFORGE_ENFORCEMENT_STATE_FILE"] = state_file

    p = subprocess.run(
        [sys.executable, "platform/runtime/attestation/enforcement_status.py"],
        check=True,
        capture_output=True,
        env=env,
        text=True,
    )
    out = p.stdout.strip()
    st = json.loads(out)
    assert st["enabled"] is True
    assert st["tier"] == "full"
