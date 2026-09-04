#!/usr/bin/env bash
set -euo pipefail

tf_resolve_report_dir_or_fail() {
  local repo_root="${1:?repo root required}"
  local raw_path="${2:?output path required}"
  local label="${3:-output path}"

  PYTHONPATH="$repo_root${PYTHONPATH:+:$PYTHONPATH}" \
    python3 - "$repo_root" "$raw_path" "$label" <<'PY'
from __future__ import annotations

import sys
from pathlib import Path

from scripts.lib.report_path_policy import ReportPathPolicyError, resolve_report_output_path

repo_root = Path(sys.argv[1])
raw_path = sys.argv[2]
label = sys.argv[3]

try:
    resolved = resolve_report_output_path(raw_path, repo_root=repo_root)
except ReportPathPolicyError as exc:
    print(f"[FAIL] {label}: {exc}", file=sys.stderr)
    raise SystemExit(1)

print(resolved)
PY
}
