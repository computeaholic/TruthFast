from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER = REPO_ROOT / "scripts" / "lib" / "registry_config.sh"


def _cert_dir(tmp_path: Path) -> Path:
    cert_dir = tmp_path / "certs"
    cert_dir.mkdir()
    (cert_dir / "registry.crt").write_text("placeholder", encoding="utf-8")
    (cert_dir / "registry.key").write_text("placeholder", encoding="utf-8")
    return cert_dir


def _run_validator(config: Path, cert_dir: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; registry_config_validate "$2" "$3" "30500"',
            "_",
            str(HELPER),
            str(config),
            str(cert_dir),
        ],
        capture_output=True,
        text=True,
        check=False,
    )


def _valid_config() -> str:
    return """version: 0.1
log:
  fields:
    service: registry
storage:
  filesystem:
    rootdirectory: /var/lib/registry
http:
  addr: :30500
  tls:
    certificate: /certs/registry.crt
    key: /certs/registry.key
"""


def test_valid_durable_config_is_accepted(tmp_path: Path) -> None:
    cert_dir = _cert_dir(tmp_path)
    config = tmp_path / "registry.yml"
    config.write_text(_valid_config(), encoding="utf-8")

    result = _run_validator(config, cert_dir)

    assert result.returncode == 0
    assert "REGISTRY_CONFIG_VALID=true" in result.stdout


@pytest.mark.parametrize(
    ("name", "content"),
    [
        ("empty", ""),
        ("truncated", "version: 0.1\nstorage:\n  filesystem:\n"),
        ("missing-http", "version: 0.1\nstorage:\n  filesystem:\n    rootdirectory: /var/lib/registry\n"),
        ("wrong-root", _valid_config().replace("/var/lib/registry", "/tmp/registry")),
        ("wrong-tls-cert", _valid_config().replace("/certs/registry.crt", "/tmp/registry.crt")),
        ("wrong-tls-key", _valid_config().replace("/certs/registry.key", "/tmp/registry.key")),
        ("wrong-port", _valid_config().replace("addr: :30500", "addr: :5000")),
    ],
)
def test_invalid_durable_config_is_rejected(tmp_path: Path, name: str, content: str) -> None:
    cert_dir = _cert_dir(tmp_path)
    config = tmp_path / f"{name}.yml"
    config.write_text(content, encoding="utf-8")

    result = _run_validator(config, cert_dir)

    assert result.returncode != 0
    assert "REGISTRY_CONFIG_VALID=true" not in result.stdout


def test_missing_tls_material_is_rejected(tmp_path: Path) -> None:
    cert_dir = tmp_path / "certs"
    cert_dir.mkdir()
    config = tmp_path / "registry.yml"
    config.write_text(_valid_config(), encoding="utf-8")

    result = _run_validator(config, cert_dir)

    assert result.returncode != 0


def test_missing_config_is_materialized_atomically_and_valid(tmp_path: Path) -> None:
    cert_dir = _cert_dir(tmp_path)
    config = tmp_path / "registry.yml"
    result = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; registry_config_write "$2" "$3" "30500"',
            "_",
            str(HELPER),
            str(config),
            str(cert_dir),
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert _run_validator(config, cert_dir).returncode == 0
    assert not list(tmp_path.glob("registry.yml.tmp.*"))


def test_malformed_config_is_repaired_without_replacing_data_mount(tmp_path: Path) -> None:
    cert_dir = _cert_dir(tmp_path)
    config = tmp_path / "registry.yml"
    config.write_text("not: [valid", encoding="utf-8")
    data_mount = "threadforge-registry-data"

    result = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; registry_config_write "$2" "$3" "30500"',
            "_",
            str(HELPER),
            str(config),
            str(cert_dir),
        ],
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, "REGISTRY_DATA_MOUNT": data_mount},
    )

    assert result.returncode == 0
    assert _run_validator(config, cert_dir).returncode == 0
    assert data_mount == "threadforge-registry-data"


def test_registry_hardening_validates_before_recreate_and_preserves_data_mount() -> None:
    text = (REPO_ROOT / "scripts" / "infra" / "harden_local_registry.sh").read_text(encoding="utf-8")

    assert text.index("registry_config_validate") < text.index("remove_registry_container_safely")
    assert '-v "$data_mount:/var/lib/registry"' in text
    assert "docker volume rm" not in text


def test_local_and_ci_config_paths_share_validation_but_keep_distinct_producers() -> None:
    bootstrap = (REPO_ROOT / "scripts" / "infra" / "bootstrap.sh").read_text(encoding="utf-8")
    ci_provision = (REPO_ROOT / "scripts" / "ci" / "provision_ci_disposable_certs.sh").read_text(encoding="utf-8")

    assert "registry_config_write" in bootstrap
    assert "THREADFORGE_EXECUTION_PROFILE:-local" in bootstrap
    assert "CI_REGISTRY_CONFIG" in ci_provision
    assert "addr: :${REGISTRY_PORT}" in ci_provision


def test_registry_config_contract_has_no_plaintext_or_unpinned_fallback() -> None:
    text = HELPER.read_text(encoding="utf-8")

    assert "certificate: /certs/registry.crt" in text
    assert "key: /certs/registry.key" in text
    assert "http:" in text
    assert "REGISTRY_CONFIG_VALID=true" in text
    assert "http.addr" in text


def test_registry_config_writer_does_not_publish_partial_destination() -> None:
    text = HELPER.read_text(encoding="utf-8")

    assert 'mktemp "${destination}.tmp.XXXXXX"' in text
    assert 'mv -f "$temporary_path" "$destination"' in text
    assert text.index('mv -f "$temporary_path" "$destination"') > text.index("registry_config_validate")


def test_bootstrap_emits_explicit_rejection_and_regeneration_markers() -> None:
    text = (REPO_ROOT / "scripts" / "infra" / "bootstrap.sh").read_text(encoding="utf-8")

    assert "REGISTRY_CONFIG_REJECTED=" in text
    assert "REGISTRY_CONFIG_REGENERATED=true" in text
    assert "local registry config producer failed validation" in text


def test_generated_config_uses_the_named_registry_data_contract() -> None:
    text = (REPO_ROOT / "scripts" / "infra" / "harden_local_registry.sh").read_text(encoding="utf-8")

    assert 'REGISTRY_DATA_DEST="/var/lib/registry"' in text
    assert 'data_mount="$(resolve_registry_data_mount)"' in text
    assert '-v "$data_mount:/var/lib/registry"' in text
