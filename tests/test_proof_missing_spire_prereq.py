import os
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]

pytestmark = pytest.mark.unit


def test_proof_missing_spire_fails_fast(tmp_path):
    mockbin = tmp_path / "mockbin"
    mockbin.mkdir()

    kubectl = mockbin / "kubectl"
    kubectl.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        'case "$*" in\n'
        '  "cluster-info")\n'
        "    exit 0\n"
        "    ;;\n"
        '  "get nodes --no-headers")\n'
        "    printf 'kind-control-plane   Ready    control-plane\\n'\n"
        "    ;;\n"
        '  "wait --for=condition=Ready nodes --all --timeout=30s")\n'
        "    exit 0\n"
        "    ;;\n"
        '  "get ns istio-system")\n'
        "    exit 0\n"
        "    ;;\n"
        '  "get ns kyverno")\n'
        "    exit 0\n"
        "    ;;\n"
        '  "get pods -n spire-system -l app=spire-server -o json")\n'
        "    printf '{\"items\": []}\\n'\n"
        "    ;;\n"
        "  *)\n"
        "    printf 'unexpected kubectl args: %s\\n' \"$*\" >&2\n"
        "    exit 1\n"
        "    ;;\n"
        "esac\n"
    )
    kubectl.chmod(0o755)

    proc = subprocess.run(
        # Keep this shell snippet exact while formatting for line length.
        # It validates real prereq signaling and messaging.
        [
            "bash",
            "-euo",
            "pipefail",
            "-c",
            (
                ". scripts/lib/proof_prereqs.sh; "
                'require_spire_server_ready_or_missing_prereq "control plane not initialized '
                '— spire-server not ready"'
            ),
        ],
        cwd=REPO_ROOT,
        env={**os.environ, "PATH": f"{mockbin}:{os.environ['PATH']}"},
        capture_output=True,
        text=True,
        check=False,
    )

    output = proc.stdout + proc.stderr
    assert proc.returncode == 10
    assert "MISSING_PREREQ" in output
    assert "make infra-bootstrap" in output
    assert "spire-server not ready" in output
