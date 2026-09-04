from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import sys


REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER = REPO_ROOT / "scripts/lib/observability_transport.sh"
CHECK = REPO_ROOT / "scripts/advisory/observability/observability_check.sh"


def _fake_kubectl(tmp_path: Path, mode: str) -> Path:
    tmp_path.mkdir(parents=True, exist_ok=True)
    executable = tmp_path / "kubectl"
    executable.write_text(
        f"#!{sys.executable}\n"
        "import os\n"
        "import signal\n"
        "import socket\n"
        "import sys\n"
        "import time\n"
        "\n"
        f"MODE = {mode!r}\n"
        "args = sys.argv[1:]\n"
        "if args[:2] == ['get', 'service']:\n"
        "    if MODE == 'service-absent':\n"
        "        print('service not found', file=sys.stderr)\n"
        "        raise SystemExit(1)\n"
        "    raise SystemExit(0)\n"
        "if args[:2] == ['get', 'endpoints']:\n"
        "    if MODE == 'no-endpoints':\n"
        "        raise SystemExit(0)\n"
        "    print('10.0.0.1')\n"
        "    raise SystemExit(0)\n"
        "if args and args[0] == 'get':\n"
        "    raise SystemExit(0)\n"
        "if args and args[0] == 'port-forward':\n"
        "    mapping = next(value for value in args if ':' in value and value.split(':', 1)[0].isdigit())\n"
        "    local_port = int(mapping.split(':', 1)[0])\n"
        "    if MODE == 'exit':\n"
        "        print('forwarding unavailable', file=sys.stderr)\n"
        "        raise SystemExit(17)\n"
        "    if MODE == 'never-bind':\n"
        "        print('forwarding stalled', file=sys.stderr)\n"
        "        while True:\n"
        "            time.sleep(1)\n"
        "    listener = socket.socket()\n"
        "    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n"
        "    listener.bind(('127.0.0.1', local_port))\n"
        "    listener.listen(1)\n"
        "    print(f'Forwarding from 127.0.0.1:{local_port}', file=sys.stderr, flush=True)\n"
        "    signal.pause()\n"
        "raise SystemExit(0)\n",
        encoding="utf-8",
    )
    executable.chmod(0o755)
    return executable


def _run_helper(tmp_path: Path, mode: str, port: int = 39090) -> subprocess.CompletedProcess[str]:
    kubectl = _fake_kubectl(tmp_path, mode)
    harness = f"""
set -euo pipefail
source {HELPER!s}
trap observability_pf_cleanup EXIT
observability_pf_open demo observability {port} 9090
echo TRANSPORT_READY
"""
    env = {
        **os.environ,
        "KUBECTL_BIN": str(kubectl),
        "OBSERVABILITY_PF_LOG_DIR": str(tmp_path / "logs"),
        "OBSERVABILITY_PF_STARTUP_TIMEOUT_SECONDS": "1",
        "OBSERVABILITY_PF_POLL_INTERVAL_SECONDS": "0.05",
    }
    return subprocess.run(["bash", "-c", harness], capture_output=True, text=True, env=env)


def test_healthy_transport_is_ready_and_cleaned(tmp_path: Path) -> None:
    result = _run_helper(tmp_path, "healthy")
    assert result.returncode == 0, result.stderr
    assert "TRANSPORT_READY" in result.stdout
    assert "[OBSERVABILITY_TRANSPORT_READY]" in result.stdout


def test_exited_forward_is_transport_failure_with_preserved_stderr(tmp_path: Path) -> None:
    result = _run_helper(tmp_path, "exit")
    assert result.returncode != 0
    assert "OBSERVABILITY_TRANSPORT_FAILURE" in result.stderr
    assert "forwarding unavailable" in result.stderr
    assert list((tmp_path / "logs").glob("*.stderr"))


def test_never_bound_forward_fails_within_budget(tmp_path: Path) -> None:
    result = _run_helper(tmp_path, "never-bind")
    assert result.returncode != 0
    assert "did not bind local port" in result.stderr


def test_service_and_endpoint_failures_are_explicit(tmp_path: Path) -> None:
    absent = _run_helper(tmp_path / "absent", "service-absent")
    no_endpoints = _run_helper(tmp_path / "endpoints", "no-endpoints")
    assert "OBSERVABILITY_BACKEND_UNAVAILABLE" in absent.stderr
    assert "service observability/demo is absent" in absent.stderr
    assert "OBSERVABILITY_BACKEND_UNAVAILABLE" in no_endpoints.stderr
    assert "has no ready endpoints" in no_endpoints.stderr


def test_transport_cleanup_does_not_use_global_port_kill_or_fixed_sleep() -> None:
    text = HELPER.read_text(encoding="utf-8")
    assert "fuser" not in text
    assert "pkill" not in text
    assert "sleep 2" not in text
    assert "OBSERVABILITY_PF_PIDS" in text
    assert "kill \"$pid\"" in text
    assert "observability_pf_port_bound" in text


def test_supported_gate_uses_canonical_transport_and_stops_on_transport_failure() -> None:
    text = CHECK.read_text(encoding="utf-8")
    assert 'source "$SCRIPT_DIR/../../lib/observability_transport.sh"' in text
    assert "observability_pf_open \"$@\"" in text
    assert "sleep 2" not in text
    assert "fuser -k" not in text
    assert 'PROM_URL="${PROM_URL:-http://127.0.0.1:19090}"' in text
    assert 'GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:19300}"' in text
    assert 'export PROM_URL LOKI_URL TEMPO_OTLP_URL TEMPO_API_URL GRAFANA_URL' in text
    assert 'os.environ.get("PROM_URL", "http://127.0.0.1:19090")' in text


def test_transport_failure_does_not_fabricate_twenty_two_backend_failures(tmp_path: Path) -> None:
    kubectl = _fake_kubectl(tmp_path, "exit")
    env = {
        **os.environ,
        "PATH": f"{tmp_path}:{os.environ['PATH']}",
        "KUBECTL_BIN": str(kubectl),
        "OBSERVABILITY_PF_LOG_DIR": str(tmp_path / "logs"),
        "OBSERVABILITY_PF_STARTUP_TIMEOUT_SECONDS": "1",
        "OBSERVABILITY_PF_POLL_INTERVAL_SECONDS": "0.05",
    }
    result = subprocess.run(["bash", str(CHECK)], capture_output=True, text=True, env=env)
    assert result.returncode != 0
    assert "OBSERVABILITY_TRANSPORT_FAILURE" in result.stderr
    assert "22 FAILED" not in result.stdout


def test_release_gate_contains_no_silent_background_forward_pattern() -> None:
    text = CHECK.read_text(encoding="utf-8")
    assert not re.search(r"port-forward[\s\S]{0,220}>/dev/null 2>&1 &", text)
