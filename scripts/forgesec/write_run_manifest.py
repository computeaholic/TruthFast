#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: write_run_manifest.py <forgesec_run_dir>", file=sys.stderr)
        return 1

    out_dir = Path(sys.argv[1]).resolve()
    manifest = {
        "run_id": out_dir.name,
        "identity": json.loads((out_dir / "identity" / "report.json").read_text(encoding="utf-8")),
        "surface": json.loads((out_dir / "surface" / "report.json").read_text(encoding="utf-8")),
    }
    (out_dir / "run_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
