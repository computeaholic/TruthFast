from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.core

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "supply_chain" / "collect_images.sh"
CERT_MANAGER_RUNTIME_IMAGES = REPO_ROOT / "platform" / "deploy" / "infra" / "cert-manager" / "runtime-images.yaml"
OBSERVABILITY_GRAFANA = REPO_ROOT / "platform" / "deploy" / "infra" / "observability" / "base" / "grafana.yaml"
OBSERVABILITY_PROMETHEUS = REPO_ROOT / "platform" / "deploy" / "infra" / "observability" / "base" / "prometheus.yaml"
AGENT_CONTAINMENT_RESOLVED = REPO_ROOT / "platform" / "labs" / "agent-containment" / "k8s" / "deployments.resolved.yaml"
AGENT_CONTAINMENT_SOURCE = REPO_ROOT / "platform" / "labs" / "agent-containment" / "k8s" / "deployments.yaml"
ROGUE_AGENT_IMAGE = "registry.threadforge.local:30500/agents-lab/rogue-agent@sha256:22ba4b8560f321e1550915ae768132743c7d94e1ddad410329dedc7d57b03586"


def _image_refs(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    return [line.split("image:", 1)[1].strip() for line in text.splitlines() if "image:" in line]


def test_managed_collection_includes_cert_manager_runtime_images(tmp_path: Path) -> None:
    output_path = tmp_path / "images.txt"
    env = os.environ.copy()
    env.setdefault("PATH", os.environ["PATH"])

    result = subprocess.run(
        ["bash", str(SCRIPT), "--output", str(output_path), "--scope", "managed"],
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert output_path.exists()

    runtime_images_text = CERT_MANAGER_RUNTIME_IMAGES.read_text(encoding="utf-8")
    expected_refs = [line.split("image:", 1)[1].strip() for line in runtime_images_text.splitlines() if "image:" in line]
    assert expected_refs, "cert-manager runtime images file did not contain any image references"

    collected_refs = {
        line.strip()
        for line in output_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    }
    for ref in expected_refs:
        assert ref in collected_refs, f"missing managed runtime image from collection: {ref}"


def test_managed_collection_includes_observability_runtime_images(tmp_path: Path) -> None:
    output_path = tmp_path / "images.txt"
    env = os.environ.copy()
    env.setdefault("PATH", os.environ["PATH"])

    result = subprocess.run(
        ["bash", str(SCRIPT), "--output", str(output_path), "--scope", "managed"],
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert output_path.exists()

    expected_refs: list[str] = []
    for runtime_file in (OBSERVABILITY_GRAFANA, OBSERVABILITY_PROMETHEUS):
        runtime_text = runtime_file.read_text(encoding="utf-8")
        expected_refs.extend(
            line.split("image:", 1)[1].strip()
            for line in runtime_text.splitlines()
            if "image:" in line
        )

    assert expected_refs, "observability runtime images files did not contain any image references"

    collected_refs = {
        line.strip()
        for line in output_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    }
    for ref in expected_refs:
        assert ref in collected_refs, f"missing managed runtime image from collection: {ref}"


def test_cluster_collection_includes_agent_containment_runtime_images(tmp_path: Path) -> None:
    output_path = tmp_path / "images.txt"
    env = os.environ.copy()
    env.setdefault("PATH", os.environ["PATH"])

    result = subprocess.run(
        ["bash", str(SCRIPT), "--output", str(output_path), "--scope", "cluster"],
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert output_path.exists()

    runtime_text = AGENT_CONTAINMENT_RESOLVED.read_text(encoding="utf-8")
    expected_refs = [line.split("image:", 1)[1].strip() for line in runtime_text.splitlines() if "image:" in line]
    assert expected_refs, "agent containment resolved manifests did not contain any image references"

    collected_refs = {
        line.strip()
        for line in output_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    }
    for ref in expected_refs:
        assert ref in collected_refs, f"missing cluster runtime image from collection: {ref}"
    assert ROGUE_AGENT_IMAGE in collected_refs, "missing rogue-agent runtime image from cluster collection"


def test_cluster_collection_excludes_historical_core_agent_source_images(tmp_path: Path) -> None:
    output_path = tmp_path / "images.txt"
    env = os.environ.copy()
    env.setdefault("PATH", os.environ["PATH"])

    result = subprocess.run(
        ["bash", str(SCRIPT), "--output", str(output_path), "--scope", "cluster"],
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert output_path.exists()

    script_text = SCRIPT.read_text(encoding="utf-8")
    assert '"platform/labs/agent-containment/k8s/deployments.yaml"' in script_text

    historical_refs = sorted(set(_image_refs(AGENT_CONTAINMENT_SOURCE)) - set(_image_refs(AGENT_CONTAINMENT_RESOLVED)))

    collected_refs = {
        line.strip()
        for line in output_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    }
    for ref in historical_refs:
        assert ref not in collected_refs, f"historical source image leaked into cluster collection: {ref}"
