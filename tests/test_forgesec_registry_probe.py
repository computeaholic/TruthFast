from __future__ import annotations

import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_registry_probe_reconciles_changed_container_ip(tmp_path: Path) -> None:
    hosts = tmp_path / "hosts"
    hosts.write_text("127.0.0.1 localhost\n172.18.0.2 registry.threadforge.local\n", encoding="utf-8")
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "docker").write_text(
        "#!/usr/bin/env bash\nprintf '%s\\n' \"${REGISTRY_TEST_IP}\"\n",
        encoding="utf-8",
    )
    (fake_bin / "docker").chmod(0o755)

    script = """
    source scripts/lib/registry_probe.sh
    registry_probe_reconcile_host_dns registry.threadforge.local threadforge-registry
    """
    env = os.environ | {
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "REGISTRY_HOSTS_FILE": str(hosts),
        "REGISTRY_TEST_IP": "172.18.0.3",
    }
    subprocess.run(["bash", "-c", script], cwd=ROOT, env=env, check=True)
    assert hosts.read_text(encoding="utf-8").count("registry.threadforge.local") == 1
    assert "172.18.0.3 registry.threadforge.local" in hosts.read_text(encoding="utf-8")


def test_forgesec_registry_operations_use_dynamic_host_reconciliation() -> None:
    helper = (ROOT / "scripts/lib/registry_probe.sh").read_text(encoding="utf-8")
    ensure = (ROOT / "scripts/forgesec/ensure_canonical_image.sh").read_text(encoding="utf-8")
    signing = (ROOT / "scripts/supply_chain/sign_images.sh").read_text(encoding="utf-8")

    assert "registry_probe_reconcile_host_dns" in helper
    assert "172.18.0.2" not in helper
    assert 'source "$REPO_ROOT/scripts/lib/registry_probe.sh"' in ensure
    assert 'source "$REPO_ROOT/scripts/lib/registry_probe.sh"' in signing
    assert "registry_probe_reconcile_host_dns" in ensure
    assert "registry_probe_reconcile_host_dns" in signing
