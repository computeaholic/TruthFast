#!/usr/bin/env python3
"""CLI: print enforcement readiness as JSON for operator integration.

Usage: runtime/attestation/enforcement_status.py
Outputs: {"enabled": bool, "tier": "none"|"partial"|"full"}
"""

from __future__ import annotations

import json
import os
import sys

# Ensure repo root is on PYTHONPATH when executed directly
repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if repo_root not in sys.path:
    sys.path.insert(0, repo_root)

from runtime.metrics.enforcement import get_enforcement_ready  # noqa: E402

if __name__ == "__main__":
    st = get_enforcement_ready()
    print(json.dumps(st))
