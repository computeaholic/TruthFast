"""Tests for attestor evidence metadata (naming & retention hints).

These tests are intentionally shallow and only assert presence of the metadata
fields in the written attestation JSON. They do not change attestation semantics.
"""

from __future__ import annotations

import json
import os
from subprocess import PIPE, run

import pytest

pytestmark = pytest.mark.unit


def test_attestor_writes_evidence_metadata(tmp_path):
    env = os.environ.copy()
    env["EVIDENCE_DIR"] = str(tmp_path / "e")

    # Execute attestor; it will fail fast due to missing cluster resources but should
    # still write attestation result JSON with evidence metadata.
    r = run(["bash", "platform/runtime/attestation/collector_attestor.sh"], env=env, stdout=PIPE, stderr=PIPE)

    # Locate any attestation.json file
    found = list((tmp_path / "e").glob("**/attestation.json"))
    assert found, "attestation.json not produced"

    data = json.loads(found[0].read_text())
    assert data.get("evidence_metadata") is not None
    assert data["evidence_metadata"].get("name") is not None
    assert data["evidence_metadata"].get("retain_days") == 7
