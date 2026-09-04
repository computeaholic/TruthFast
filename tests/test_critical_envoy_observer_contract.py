from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess


REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER = REPO_ROOT / "scripts/lib/envoy_admin.sh"
CRITICAL_RUNTIME_OBSERVERS = (
    "scripts/infra/enforce-spire-only-invariants.sh",
    "scripts/verify/converge_spire_root.sh",
    "scripts/verify/enforce_spire_single_ca.sh",
    "scripts/verify/spire-runtime-sweep.sh",
    "scripts/verify/verify_runtime_sidecar_contract.sh",
)


def _fake_kubectl(tmp_path: Path, payload: dict[str, object], returncode: int = 0) -> Path:
    executable = tmp_path / "kubectl"
    executable.write_text(
        "#!/usr/bin/env bash\n"
        f"if [[ {returncode} -ne 0 ]]; then exit {returncode}; fi\n"
        "cat <<'JSON'\n"
        f"{json.dumps(payload)}\n"
        "JSON\n",
        encoding="utf-8",
    )
    executable.chmod(0o755)
    return executable


def test_envoy_secret_observer_normalizes_proxy_local_config_dump(tmp_path: Path) -> None:
    payload = {
        "configs": [
            {
                "@type": "type.googleapis.com/envoy.admin.v3.SecretsConfigDump",
                "dynamic_active_secrets": [{"name": "default", "secret": {"tls_certificate": {}}}],
                "static_secrets": [],
            }
        ]
    }
    kubectl = _fake_kubectl(tmp_path, payload)
    output = tmp_path / "secrets.json"

    subprocess.run(
        ["bash", str(HELPER), "capture-secrets", "namespace", "pod", str(output)],
        check=True,
        env={**os.environ, "KUBECTL_BIN": str(kubectl)},
    )

    result = json.loads(output.read_text(encoding="utf-8"))
    assert result == {
        "dynamicActiveSecrets": [{"name": "default", "secret": {"tlsCertificate": {}}}],
        "staticSecrets": [],
    }


def test_envoy_observer_failure_is_nonzero_and_does_not_create_evidence(tmp_path: Path) -> None:
    kubectl = _fake_kubectl(tmp_path, {}, returncode=19)
    output = tmp_path / "secrets.json"

    result = subprocess.run(
        ["bash", str(HELPER), "capture-secrets", "namespace", "pod", str(output)],
        check=False,
        env={**os.environ, "KUBECTL_BIN": str(kubectl)},
    )

    assert result.returncode != 0
    assert not output.exists()


def test_release_critical_envoy_observers_do_not_use_istioctl_secret_transport() -> None:
    for relative_path in CRITICAL_RUNTIME_OBSERVERS:
        text = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
        tokens = re.findall(r"[A-Za-z0-9_-]+", text)
        assert not any(
            tokens[index : index + 3] == ["istioctl", "proxy-config", "secret"]
            for index in range(len(tokens) - 2)
        ), relative_path
        assert "envoy_admin.sh" in text or "http://127.0.0.1:15000/config_dump" in text


def test_runtime_sweep_one_shot_does_not_swallow_observer_failures() -> None:
    text = (REPO_ROOT / "scripts/verify/spire-runtime-sweep.sh").read_text(encoding="utf-8")

    assert "Envoy SDS observation UNOBSERVABLE" in text
    assert "Envoy certificate observation UNOBSERVABLE" in text
    assert "check_all_sidecars_use_spire_issuer || true" not in text
    assert 'exit "$failed"' in text


def test_spire_only_rotation_contract_uses_state_not_recent_log_activity() -> None:
    text = (REPO_ROOT / "scripts/infra/enforce-spire-only-invariants.sh").read_text(encoding="utf-8")

    assert "CreateCertificate succeeded" not in text
    assert "ISTIO_META_CERT_SIGNER" in text
    assert "status.readyReplicas" in text
    assert "endpoints spire-csr" in text
    assert "static identity secrets bypass SDS rotation" in text


def test_host_trust_prime_checks_the_privileged_operation_it_will_execute() -> None:
    text = (REPO_ROOT / "scripts/infra/host_trust_prime.sh").read_text(encoding="utf-8")

    assert "sudo -n true" in text
    assert "sudo -n -v" not in text
