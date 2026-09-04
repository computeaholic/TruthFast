from pathlib import Path
import os
import subprocess

import pytest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parent.parent
PREPARE_NAMESPACE = ROOT / "scripts" / "install" / "prepare_namespace.sh"
NAMESPACE_MANIFEST = ROOT / "platform" / "labs" / "agent-containment" / "k8s" / "namespace.yaml"
SERVICEACCOUNTS = ROOT / "platform" / "labs" / "agent-containment" / "k8s" / "serviceaccounts.yaml"


def test_agents_lab_namespace_is_created_atomically_with_istio_label() -> None:
    script = PREPARE_NAMESPACE.read_text(encoding="utf-8")
    manifest = NAMESPACE_MANIFEST.read_text(encoding="utf-8")
    serviceaccounts = SERVICEACCOUNTS.read_text(encoding="utf-8")

    assert "kubectl apply -f" in script
    assert "platform/labs/agent-containment/k8s/namespace.yaml" in script
    assert "kubectl label namespace" not in script
    assert "kubectl create namespace" not in script
    assert "kind: Namespace" in manifest
    assert "name: agents-lab" in manifest
    assert "istio-injection: enabled" in manifest
    assert "sidecar.istio.io/proxyImage" in manifest
    assert "registry.threadforge.local:30500/istio/proxyv2@sha256:2f78ddd13cbf6f600c8bebb9f05b21f9b14e047ec5f8c88ef9f50abc8e14466b" in manifest
    assert "name: rogue-agent" in serviceaccounts
    assert "namespace: agents-lab" in serviceaccounts


def test_prepare_namespace_fails_closed_when_injection_label_is_missing(tmp_path: Path) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_kubectl = fake_bin / "kubectl"
    fake_kubectl.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "if [[ \"$*\" == *\"get namespace agents-lab\"* ]]; then\n"
        "  printf '%s' disabled\n"
        "  exit 0\n"
        "fi\n"
        "if [[ \"$1\" == apply ]]; then exit 0; fi\n"
        "exit 99\n",
        encoding="utf-8",
    )
    fake_kubectl.chmod(0o755)

    result = subprocess.run(
        ["bash", str(PREPARE_NAMESPACE)],
        cwd=ROOT,
        env={**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}"},
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    assert "[FAIL] Namespace agents-lab is not labeled for sidecar injection" in result.stdout
    assert "[ADVISORY-FAIL]" not in result.stdout
