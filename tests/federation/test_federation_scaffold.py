import subprocess
from pathlib import Path

import pytest
from fastapi import HTTPException

REPO_ROOT = Path(__file__).resolve().parents[2]
F_PATH = REPO_ROOT / "platform" / "deploy" / "infra" / "spire" / "templates" / "federation.yaml"

pytestmark = pytest.mark.unit


def test_federation_file_exists_and_disabled():
    assert F_PATH.exists(), "federation.yaml must exist as disabled scaffold"
    txt = F_PATH.read_text()
    assert "enabled: false" in txt, "federation.yaml must be disabled by default"


def test_no_runtime_references_to_federation_yaml():
    # Ensure no python runtime code references federation.yaml
    out = subprocess.run(
        ["grep", "-R", "-F", "--line-number", "federation.yaml", "api", "runtime", "scripts", "tests"],
        capture_output=True,
        text=True,
    )
    lines = out.stdout.strip().splitlines()
    # Only this file should reference federation.yaml
    # Filter out the template itself and the test file
    filtered = [
        line
        for line in lines
        if "platform/deploy/infra/spire/templates/federation.yaml" not in line
        and "tests/federation/test_federation_scaffold.py" not in line
    ]
    assert filtered == [], f"Unexpected references to federation.yaml: {filtered}"


def test_foreign_spiffe_rejected_by_default():
    """Foreign identity supplied through the canonical proxy contract is denied."""
    from runtime.api.identity_deps import extract_identity_from_proxy_headers

    foreign = "spiffe://foreign.example/ns/test/sa/x"
    with pytest.raises(HTTPException) as exc:
        extract_identity_from_proxy_headers(f"URI={foreign}")

    assert exc.value.status_code == 401
    assert exc.value.detail == "Authenticated proxy identity is invalid"
