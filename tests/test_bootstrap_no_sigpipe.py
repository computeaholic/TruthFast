from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
VERIFY_SCRIPT = REPO_ROOT / "scripts/verify/verify_control_plane_ready.sh"


def _write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def test_verify_control_plane_ready_empty_pods_fails_classified_not_sigpipe(tmp_path: Path) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir(parents=True, exist_ok=True)

    _write_executable(
        fake_bin / "kubectl",
        """#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "wait" ]]; then
  echo "error: timed out waiting for the condition" >&2
  exit 1
fi
if [[ "$1" == "get" && "$2" == "svc" && "$3" == "kyverno-svc" ]]; then
  exit 0
fi
if [[ "$1" == "get" && "$2" == "endpoints" && "$3" == "kyverno-svc" ]]; then
  printf '%s\n' '{"subsets":[{"addresses":[{"ip":"10.0.0.1"}],"ports":[{"port":443}]}]}'
  exit 0
fi
exit 0
""",
    )

    _write_executable(
        fake_bin / "curl",
        """#!/usr/bin/env bash
set -euo pipefail
printf '200'
""",
    )

    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}:{env['PATH']}"
    env["CONTROL_PLANE_TIMEOUT_SECONDS"] = "1"
    env["CONTROL_PLANE_INTERVAL_SECONDS"] = "1"

    result = subprocess.run(
        [str(VERIFY_SCRIPT)],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )

    combined = (result.stdout or "") + (result.stderr or "")
    assert result.returncode != 141
    assert result.returncode == 2
    assert "[FAIL] CONTROL PLANE NOT READY" in combined
