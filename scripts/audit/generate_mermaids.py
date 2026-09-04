#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) not in {2, 3}:
        print("Usage: generate_mermaids.py <audit_dir> [mermaid_output_dir]", file=sys.stderr)
        return 1

    repo_root = Path(__file__).resolve().parents[2]
    generator = repo_root / "scripts" / "generate_mermaids.py"
    command = [sys.executable, str(generator), sys.argv[1]]
    if len(sys.argv) == 3:
        command.append(sys.argv[2])

    return subprocess.run(command, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
