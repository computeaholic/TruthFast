from __future__ import annotations

import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.core

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "verify" / "verify_required_registry_images.sh"
SOURCE_CA = REPO_ROOT / "certs" / "threadforge-ingress-ca.crt"


def _make_fake_skopeo(tmp_path: Path, mode: str) -> Path:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    skopeo = bin_dir / "skopeo"
    skopeo.write_text(
        """#!/usr/bin/env bash
set -euo pipefail
mode="${FAKE_SKOPEO_MODE:-success}"
cmd="${1:-}"
shift || true
case "$cmd" in
  inspect)
    ref=""
    for arg in "$@"; do
      ref="$arg"
    done
    case "$mode" in
      success)
        printf '%s\n' "${ref##*@}"
        ;;
      tls_fail)
        printf '%s\n' "x509: certificate signed by unknown authority" >&2
        exit 1
        ;;
      manifest_missing)
        printf '%s\n' "manifest unknown" >&2
        exit 1
        ;;
      *)
        printf '%s\n' "unexpected fake skopeo mode: $mode" >&2
        exit 2
        ;;
    esac
    ;;
  *)
    printf '%s\n' "unexpected fake skopeo command: $cmd" >&2
    exit 2
    ;;
esac
""",
        encoding="utf-8",
    )
    skopeo.chmod(skopeo.stat().st_mode | stat.S_IEXEC)
    return bin_dir


def _run_script(env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    merged_env = os.environ.copy()
    for name in (
        "CERT_MANAGER_CONTROLLER_IMAGE",
        "CERT_MANAGER_CAINJECTOR_IMAGE",
        "CERT_MANAGER_WEBHOOK_IMAGE",
        "CERT_MANAGER_STARTUPAPICHECK_IMAGE",
        "ISTIO_PILOT_IMAGE",
        "SPIRE_SERVER_IMAGE",
        "SPIRE_AGENT_IMAGE",
    ):
        merged_env.pop(name, None)
    merged_env.update(env)
    return subprocess.run(
        ["bash", str(SCRIPT)],
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        env=merged_env,
        check=False,
    )


def test_required_registry_images_pass_with_valid_cert_material(tmp_path: Path) -> None:
    cert_path = tmp_path / "threadforge-ingress-ca.crt"
    shutil.copy2(SOURCE_CA, cert_path)
    bin_dir = _make_fake_skopeo(tmp_path, "success")

    result = _run_script(
        {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FAKE_SKOPEO_MODE": "success",
            "REGISTRY_CA_CERT_PATH": str(cert_path),
        }
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert "[PASS] required registry images are present and digest pinned" in result.stdout


def test_required_registry_images_fail_closed_when_cert_material_missing(tmp_path: Path) -> None:
    bin_dir = _make_fake_skopeo(tmp_path, "success")
    missing_cert = tmp_path / "missing" / "threadforge-ingress-ca.crt"

    result = _run_script(
        {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FAKE_SKOPEO_MODE": "success",
            "REGISTRY_CA_CERT_PATH": str(missing_cert),
        }
    )

    assert result.returncode == 2
    assert "registry CA cert missing" in result.stdout


def test_required_registry_images_classify_registry_tls_failure_without_mislabeling_missing_images(
    tmp_path: Path,
) -> None:
    cert_path = tmp_path / "threadforge-ingress-ca.crt"
    shutil.copy2(SOURCE_CA, cert_path)
    bin_dir = _make_fake_skopeo(tmp_path, "tls_fail")

    result = _run_script(
        {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FAKE_SKOPEO_MODE": "tls_fail",
            "REGISTRY_CA_CERT_PATH": str(cert_path),
        }
    )

    assert result.returncode == 11
    assert "REGISTRY_TLS_FAILURE" in result.stdout
    assert "MISSING_IMAGE" not in result.stdout


def test_required_registry_images_still_report_missing_manifest_as_missing_image(tmp_path: Path) -> None:
    cert_path = tmp_path / "threadforge-ingress-ca.crt"
    shutil.copy2(SOURCE_CA, cert_path)
    bin_dir = _make_fake_skopeo(tmp_path, "manifest_missing")

    result = _run_script(
        {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FAKE_SKOPEO_MODE": "manifest_missing",
            "REGISTRY_CA_CERT_PATH": str(cert_path),
        }
    )

    assert result.returncode == 11
    assert "MISSING_IMAGE" in result.stdout
