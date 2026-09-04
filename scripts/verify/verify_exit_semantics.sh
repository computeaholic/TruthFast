#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/fail.sh
source "$REPO_ROOT/scripts/lib/fail.sh"

if ! command -v python3 >/dev/null 2>&1; then
  fail_system "python3 not found in PATH"
fi

python3 - "$REPO_ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
scripts_dir = root / "scripts"

patterns = [
    "verify/**/*.sh",
    "verify*.sh",
    "enforce*.sh",
    "test_*admission*.sh",
    "test_ephemeral_containers.sh",
]

files = set()
for pat in patterns:
    for p in scripts_dir.glob(pat):
        if p.is_file():
            files.add(p)

policy_context = re.compile(
    r"\[POLICY VIOLATION\]|fail_policy\(|POLICY VIOLATION",
    re.IGNORECASE,
)

violations: list[str] = []
for path in sorted(files):
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    for idx, line in enumerate(lines, start=1):
        if not re.search(r"\bexit\s+1\b", line):
            continue
        context = "\n".join(lines[max(0, idx - 4):idx + 2])
        if policy_context.search(context):
            rel = path.relative_to(root).as_posix()
            violations.append(f"{rel}:{idx}: exit 1 used in policy-violation path")

if violations:
    for v in violations:
        print(f"[FAIL] {v}")
    raise SystemExit(2)

print("[PASS] exit semantics validation passed for verify/enforcement/admission scripts")
print("EXIT_SEMANTICS_CONSISTENT=TRUE")
PY
