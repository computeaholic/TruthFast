from pathlib import Path
import os
import subprocess

import pytest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parent.parent
BOOTSTRAP = ROOT / "scripts" / "infra" / "bootstrap.sh"


def test_bootstrap_recreates_spire_csr_before_applying_kustomize() -> None:
    text = BOOTSTRAP.read_text()
    refresh_text = (ROOT / "scripts" / "verify" / "refresh_spire_istio_ca_path.sh").read_text()
    preistio_start = text.index('echo "[bootstrap] running istiod readiness prechecks (pre-istio-base-install)"')
    preistio_end = text.index('echo "[bootstrap] installing Istio"', preistio_start)
    preistio_block = text[preistio_start:preistio_end]

    delete_line = "kubectl -n istio-system delete deployment spire-csr --ignore-not-found >/dev/null 2>&1 || true"
    apply_line = "kubectl apply -k platform/deploy/infra/spire-csr >/dev/null"
    refresh_delete = 'kubectl delete pod -n istio-system -l app=spire-csr --ignore-not-found >/dev/null'
    reader_helper = 'bash "$REPO_ROOT/scripts/infra/ensure_spire_root_key_reader.sh"'

    assert delete_line in text
    assert apply_line in text
    assert text.index(delete_line) < text.index(apply_line)
    assert reader_helper in text
    reader_text = (ROOT / "scripts" / "infra" / "ensure_spire_root_key_reader.sh").read_text()
    assert "spire_server_data_volume" in reader_text
    assert "clear_stale_spire_root_reader_probe" not in text
    assert "spire-root-reader-probe" not in preistio_block
    assert "reset_spire_csr_pod" in refresh_text
    assert "drop_spire_csr_init_gate" in refresh_text
    assert refresh_delete in refresh_text


def test_spire_installer_removes_legacy_stateful_server_before_recreating_deployment() -> None:
    text = (ROOT / "scripts" / "install" / "install_spire.sh").read_text()

    stateful_delete = 'kubectl delete statefulset spire-server -n "${NS}" --ignore-not-found'
    deployment_create = 'kind: Deployment'
    assert stateful_delete in text
    assert text.index(stateful_delete) < text.index(deployment_create)


def test_spire_csr_manifest_uses_live_workload_socket_path() -> None:
    text = (ROOT / "platform" / "deploy" / "infra" / "spire-csr" / "spire-csr.yaml").read_text()

    assert text.count('value: unix:///run/spire/sockets/socket') == 2
    assert 'value: unix:///run/spire/sockets/agent.sock' not in text


def test_bootstrap_spire_root_reader_probe_uses_internal_busybox_image() -> None:
    text = BOOTSTRAP.read_text()
    reader_text = (ROOT / "scripts" / "infra" / "ensure_spire_root_key_reader.sh").read_text()

    busybox_ref = (
        "${REGISTRY_HOSTPORT}/mirror/docker.io/library/busybox@sha256:"
        "bfdec45b06a48dbc7d261ace48cec2d74849ecfc5129662c979f656cb31df469"
    )

    assert busybox_ref in reader_text
    assert "curlimages/curl:8.10.1" not in text


def test_spire_agent_starts_only_after_bootstrap_publishes_bundle() -> None:
    bootstrap = BOOTSTRAP.read_text()
    values = (ROOT / "platform" / "deploy" / "infra" / "spire" / "values.yaml").read_text()
    daemonset = (ROOT / "platform" / "deploy" / "infra" / "spire" / "templates" / "spire-agent-daemonset.yaml").read_text()

    disabled_install = (
        "helm upgrade --install spire platform/deploy/infra/spire -n spire-system "
        "-f platform/deploy/infra/spire/values.yaml --set spireAgent.enabled=false --atomic=false"
    )
    bundle_publish = "kubectl create configmap spire-bundle"
    assert "spireAgent:\n  enabled: true" in values
    assert 'threadforge.io/spire-agent-disabled: "true"' in daemonset
    assert disabled_install in bootstrap
    assert bootstrap.index(disabled_install) < bootstrap.index(bundle_publish)
    assert bootstrap.index(bundle_publish) < bootstrap.index("kubectl patch daemonset spire-agent -n spire-system --type=json")


def test_spire_agent_release_waits_for_server_restart_and_zero_restart_contract() -> None:
    bootstrap = BOOTSTRAP.read_text()
    release = 'echo "[bootstrap] enabling SPIRE agent after trust bundle publication"'
    server_restart = 'echo "[bootstrap] restarting SPIRE server before releasing agent scheduling"'
    agent_rollout = 'set_bootstrap_phase "spire-agent-rollout"'

    assert bootstrap.index(server_restart) < bootstrap.index(release)
    assert bootstrap.index(release) < bootstrap.index(agent_rollout)
    assert "spire_agent_restart_contract_failure" in bootstrap
    assert "after registration reconciliation" not in bootstrap


def test_spire_restart_contract_accepts_zero_and_rejects_nonzero(tmp_path: Path) -> None:
    helper = ROOT / "scripts" / "lib" / "spire_restart_contract.sh"
    kubectl = tmp_path / "kubectl"
    kubectl.write_text("#!/usr/bin/env bash\nprintf '%s\\n' \"${SPIRE_RESTART_COUNTS}\"\n")
    kubectl.chmod(0o755)

    def run_contract(counts: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["PATH"] = f"{tmp_path}:{env['PATH']}"
        env["SPIRE_RESTART_COUNTS"] = counts
        return subprocess.run(
            ["bash", "-c", f"source '{helper}'; spire_agent_restart_contract_failure"],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )

    assert run_contract("0").returncode == 0
    rejected = run_contract("1")
    assert rejected.returncode != 0
    assert "restartCount is non-zero (1)" in rejected.stdout
