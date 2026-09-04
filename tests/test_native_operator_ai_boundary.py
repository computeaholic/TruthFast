from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.core
REPO_ROOT = Path(__file__).resolve().parents[1]
SUPPORT_CONTRACT = REPO_ROOT / "platform/config/support_contract.json"


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def _native_workload_documents() -> list[tuple[Path, str]]:
    documents: list[tuple[Path, str]] = []
    for path in sorted((REPO_ROOT / "platform/deploy").rglob("*")):
        if path.suffix not in {".yaml", ".yml"}:
            continue
        text = path.read_text(encoding="utf-8")
        for document in re.split(r"(?m)^---\s*$", text):
            kind = re.search(r"(?m)^kind:\s*([A-Za-z]+)\s*$", document)
            if kind and kind.group(1) in {
                "DaemonSet",
                "Deployment",
                "Job",
                "Pod",
                "StatefulSet",
            }:
                documents.append((path, document))
    return documents


def test_native_spire_identity_source_has_no_operator_ai_authority() -> None:
    entries = _read("platform/identity/spire/entries.yaml")
    reconcile = _read("scripts/proof/reconcile_spire_entries.sh")
    bootstrap = _read("scripts/infra/bootstrap.sh")

    assert "operator-ai" not in entries.lower()
    assert 'TRACKED_ENTRIES_FILE="$REPO_ROOT/platform/identity/spire/entries.yaml"' in reconcile
    assert "scripts/proof/reconcile_spire_entries.sh" in bootstrap
    assert "platform/deploy/infra/spire/identity" not in bootstrap
    assert "operator-ai" not in bootstrap.lower()


def test_supported_deployment_inputs_have_no_operator_ai_workload_identity() -> None:
    for path, document in _native_workload_documents():
        assert not re.search(
            r"(?im)^\s*(?:name|serviceAccountName):\s*operator-ai\s*$", document
        ), path
        assert not re.search(r"(?i)(?:app|component):\s*operator-ai\b", document), path


def test_support_contract_excludes_operator_ai_from_native_v1() -> None:
    contract = json.loads(SUPPORT_CONTRACT.read_text(encoding="utf-8"))
    native = json.dumps(contract["supported_v1_entrypoints"]).lower()
    secondary = {item["target"]: item for item in contract["secondary_entrypoints"]}

    assert "operator-ai" not in native
    assert "runtime-deploy-api" in secondary
    assert secondary["runtime-deploy-api"]["qualification_scope"] == "SECONDARY_UNQUALIFIED"
    assert "operator-ai" not in _read("platform/config/system_map.yaml").lower()


def test_retired_identity_authorities_cannot_reenter_native_bootstrap() -> None:
    identity_root = REPO_ROOT / "platform/deploy/infra/spire/identity"
    assert not any(path.is_file() for path in identity_root.rglob("*"))
    assert not (REPO_ROOT / "platform/deploy/infra/spire/templates/registration-entries.yaml").exists()
    assert not (REPO_ROOT / "platform/deploy/infra/spire/templates/identity-apply-job.yaml").exists()
    assert not (REPO_ROOT / "platform/deploy/infra/spire/templates/spire-registration-cm.yaml").exists()

    result = subprocess.run(
        ["bash", "platform/deploy/infra/spire/apply-entries.sh"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    output = result.stdout + result.stderr
    assert result.returncode != 0
    assert "no longer authoritative" in output
    assert "entry create" not in output
