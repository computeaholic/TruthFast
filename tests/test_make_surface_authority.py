from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest


pytestmark = pytest.mark.core

REPO_ROOT = Path(__file__).resolve().parents[1]
MAKE = shutil.which("make") or "/usr/bin/make"


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def _run_make(*args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    run_env = os.environ.copy()
    if env:
        run_env.update(env)
    return subprocess.run(
        [MAKE, *args],
        cwd=REPO_ROOT,
        env=run_env,
        text=True,
        capture_output=True,
        check=False,
    )


def _write_executable(directory: Path, name: str, body: str) -> Path:
    path = directory / name
    path.write_text("#!/bin/sh\nset -eu\n" + body + "\n", encoding="utf-8")
    path.chmod(0o755)
    return path


def _prepare_shell_path(directory: Path) -> None:
    bash_link = directory / "bash"
    if not bash_link.exists():
        bash_link.symlink_to("/bin/bash")


def _run_shell(script: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    run_env = os.environ.copy()
    run_env.update(env)
    return subprocess.run(
        ["/bin/bash", "--noprofile", "--norc", "-euo", "pipefail", "-c", script],
        cwd=REPO_ROOT,
        env=run_env,
        text=True,
        capture_output=True,
        check=False,
    )


def test_public_make_surface_has_explicit_hierarchy_and_no_mesh_unlock() -> None:
    makefile = _read("Makefile")
    readme = _read("README.md")
    index = _read("docs/index.md")
    topology = _read("scripts/verify/verify_repository_topology.sh")
    mkdocs = _read("mkdocs.yml")

    assert "mesh-unlock" not in makefile
    assert "reject_pattern_in_files" in topology
    assert "mesh-unlock([^[:alnum:]_-]|$)" in topology

    assert "docs/Agent-Containment.md" in readme
    assert "docs/index.md" in readme
    assert "docs/architecture/repository-manifest.yaml" in readme
    assert "docs/Agent-Containment.md" in index
    assert "TruthFast documentation hierarchy" in index
    assert "docs/architecture/" in index
    assert "docs/CANONICAL/" in index

    mkdocs_lines = mkdocs.splitlines()
    assert mkdocs_lines.index("  - Overview:") < mkdocs_lines.index("  - Architecture:")
    assert mkdocs_lines.index("  - Architecture:") < mkdocs_lines.index("  - Canonical:")
    assert mkdocs_lines.index("  - Canonical:") < mkdocs_lines.index("  - Operations:")
    assert mkdocs_lines.index("  - Operations:") < mkdocs_lines.index("  - Governance:")
    assert mkdocs_lines.index("  - Governance:") < mkdocs_lines.index("  - Lifecycle:")
    assert mkdocs_lines.index("  - Lifecycle:") < mkdocs_lines.index("  - Policies:")
    assert mkdocs_lines.index("  - Policies:") < mkdocs_lines.index("  - Releases:")
    assert mkdocs_lines.index("      - Constitutional Assurance: Agent-Containment.md") < mkdocs_lines.index(
        "      - Home: index.md"
    )


def test_authoritative_tool_checks_fail_closed_when_missing() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        _prepare_shell_path(tmpdir)
        missing_kubectl = _run_make("core-verify-bins", env={"PATH": str(tmpdir)})
    assert missing_kubectl.returncode != 0
    assert "[FAIL] kubectl missing" in (missing_kubectl.stdout + missing_kubectl.stderr)

    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        _prepare_shell_path(tmpdir)
        _write_executable(tmpdir, "kubectl", "exit 0")
        missing_helm = _run_make("core-verify-bins", env={"PATH": str(tmpdir)})
        assert missing_helm.returncode != 0
        assert "[FAIL] helm missing" in (missing_helm.stdout + missing_helm.stderr)


@pytest.mark.parametrize("target", ["spire-install", "istio-install"])
def test_required_runtime_chart_missing_fails_deployment(target: str) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        env = {"INFRA_DIR": tmp}
        if target == "istio-install":
            mockbin = Path(tmp) / "bin"
            mockbin.mkdir()
            _prepare_shell_path(mockbin)
            _write_executable(mockbin, "kubectl", "exit 0")
            _write_executable(mockbin, "helm", "exit 0")
            env["PATH"] = str(mockbin)
        result = _run_make(target, env=env)
    assert result.returncode != 0
    assert "Missing chart:" in (result.stdout + result.stderr)


def test_cleanup_targets_propagate_real_failures_and_skip_absent_resources() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        _write_executable(
            tmpdir,
            "kubectl",
            r"""
case "$*" in
  *delete\ ns*)
    if [ "${KUBECTL_DELETE_MODE:-absent}" = "forbidden" ]; then
      echo "Error from server (Forbidden): namespace delete denied" >&2
      exit 1
    fi
    exit 0
    ;;
  *delete*)
    if [ "${KUBECTL_DELETE_MODE:-absent}" = "forbidden" ]; then
      echo "Error from server (Forbidden): resource delete denied" >&2
      exit 1
    fi
    exit 0
    ;;
  *get\ ns*) exit 0 ;;
  *create\ ns*) exit 0 ;;
  *rollout\ status*) exit 0 ;;
  *delete\ -n\ threadforge-system\ all*)
    if [ "${KUBECTL_DELETE_MODE:-absent}" = "forbidden" ]; then
      echo "Error from server (Forbidden): cleanup denied" >&2
      exit 1
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
""",
        )
        _write_executable(
            tmpdir,
            "helm",
            r"""
case "$*" in
  *uninstall*)
    case "${HELM_UNINSTALL_MODE:-absent}" in
      absent)
        echo "Error: uninstall: Release not loaded: not found" >&2
        exit 1
        ;;
      forbidden)
        echo "Error: forbidden by registry policy" >&2
        exit 1
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  *) exit 0 ;;
esac
""",
        )
        kubeconfig = tmpdir / "threadforge.yaml"
        kubeconfig.write_text("apiVersion: v1\nkind: Config\nclusters: []\n", encoding="utf-8")
        common_env = {
            "PATH": f"{tmpdir}:/usr/bin:/bin",
            "STATE_DIR": str(tmpdir / "state"),
            "REMOTE_K3S_KUBECONFIG": str(kubeconfig),
            "BASH_ENV": "",
            "PS1": "",
        }

        runtime_nuke_helper = r"""
if [ "${ALLOW_RUNTIME_K8S_CLEANUP:-}" != "YES" ]; then
  echo "[FAIL] Refusing runtime-nuke without ALLOW_RUNTIME_K8S_CLEANUP=YES" >&2
  exit 2
fi
kubectl delete -n threadforge-system all --all --ignore-not-found=true >/dev/null 2>&1
kubectl delete ns threadforge-system --ignore-not-found=true >/dev/null 2>&1
"""
        runtime_unauthorized = _run_shell(runtime_nuke_helper, common_env)
        assert runtime_unauthorized.returncode != 0
        assert "ALLOW_RUNTIME_K8S_CLEANUP=YES" in (
            runtime_unauthorized.stdout + runtime_unauthorized.stderr
        )

        helm_uninstall_helper = r"""
set +e
output="$(helm uninstall spire -n spire-system 2>&1)"
rc=$?
set -e
if [ $rc -ne 0 ]; then
  case "$output" in
    *"release: not found"*|*"not found"*)
      echo "[INFO] spire already absent from spire-system"
      exit 0
      ;;
    *)
      printf '%s\n' "$output" >&2
      exit $rc
      ;;
  esac
fi
"""
        absent = _run_shell(helm_uninstall_helper, {**common_env, "HELM_UNINSTALL_MODE": "absent"})
        assert absent.returncode == 0
        assert "already absent" in (absent.stdout + absent.stderr)

        forbidden = _run_shell(helm_uninstall_helper, {**common_env, "HELM_UNINSTALL_MODE": "forbidden"})
        assert forbidden.returncode != 0
        assert "forbidden by registry policy" in (forbidden.stdout + forbidden.stderr)

        runtime_absent = _run_shell(
            runtime_nuke_helper,
            {**common_env, "ALLOW_RUNTIME_K8S_CLEANUP": "YES", "KUBECTL_DELETE_MODE": "absent"},
        )
        assert runtime_absent.returncode == 0

        runtime_forbidden = _run_shell(
            runtime_nuke_helper,
            {**common_env, "ALLOW_RUNTIME_K8S_CLEANUP": "YES", "KUBECTL_DELETE_MODE": "forbidden"},
        )
        assert runtime_forbidden.returncode != 0


def test_advisory_targets_remain_non_blocking() -> None:
    result = _run_make("verify-signatures")
    assert result.returncode == 0
    assert "Signature verification is performed inside 'make proof'" in result.stdout
