from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest


pytestmark = pytest.mark.unit


def test_generate_sbom_writes_real_cyclonedx_output(tmp_path: Path) -> None:
    repo_root = tmp_path / "repo"
    repo_root.mkdir()
    (repo_root / "requirements").mkdir()
    (repo_root / "platform" / "deploy").mkdir(parents=True)
    (repo_root / "requirements.txt").write_text("fastapi==0.111.0\n")
    (repo_root / "requirements" / "dev.txt").write_text("pytest>=8.0\n")
    service_manifest = (
        "spec:\n  template:\n    spec:\n      containers:\n"
        "        - name: api\n"
        "          image: "
        "registry.threadforge.local:30500/threadforge-api@sha256:abc123\n"
    )
    (repo_root / "platform" / "deploy" / "service.yaml").write_text(service_manifest)

    output_path = tmp_path / "artifacts" / "audit" / "run" / "sbom" / "sbom.cdx.json"
    script_path = Path(__file__).resolve().parents[2] / "scripts" / "audit" / "generate_sbom.py"
    result = subprocess.run(
        [sys.executable, str(script_path), str(repo_root), str(output_path)], capture_output=True, text=True
    )

    assert result.returncode == 0, result.stderr
    assert output_path.exists()
    document = json.loads(output_path.read_text())
    assert document["bomFormat"] == "CycloneDX"
    assert document["components"]
    names = {component["name"] for component in document["components"]}
    assert "fastapi" in names
    assert any(component["type"] == "container" for component in document["components"])
