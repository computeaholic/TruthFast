from __future__ import annotations

import json
import shutil
import subprocess  # nosec B404: Best-effort CLI helper using an internal spire-agent binary
from typing import Optional


def fetch_x509svid_via_cli(socket_path: str) -> Optional[dict]:
    """Attempt to fetch an X509 SVID set using the `spire-agent` CLI.

    This is a best-effort helper. It runs:
      spire-agent api fetch x509svid -socketPath <socket_path>

    and expects JSON output containing PEM-encoded SVIDs and bundles. If the
    CLI is not present or the command fails, returns None.
    """
    cmd = ["spire-agent", "api", "fetch", "x509svid", "-socketPath", socket_path, "-json"]
    if shutil.which("spire-agent") is None:
        return None
    try:
        out = subprocess.check_output(
            cmd, stderr=subprocess.STDOUT, timeout=5
        )  # nosec B603: CLI helper uses internal spire-agent binary and list form
        return json.loads(out)
    except FileNotFoundError:
        return None
    except subprocess.CalledProcessError:
        return None
    except Exception:
        return None
