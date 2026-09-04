#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

python3 - <<'PY'
import os
import re
import subprocess
import sys

ROOT = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()

INTERNAL_PREFIX = "registry.threadforge.local:30500/"

EXCLUDE_PREFIXES = (
    ".venv/",
    "docs/",
    "site/",
    "site_assets/",
    "tmp/",
    "scratch/",
    "platform/deploy/infra/istio/artifacts/",
    "platform/deploy/infra/observability/evidence/",
)

SCAN_PREFIXES = (
    ".github/workflows/",
    "platform/deploy/",
    "platform/images/",
    "scripts/",
)

ALLOW_SCHEMES = ("file://", "oci://")

FORBIDDEN_STARTS = (
    "docker.io/",
    "ghcr.io/",
    "quay.io/",
    "k8s.gcr.io/",
    "gcr.io/",
    "registry.k8s.io/",
)


def is_scanned(path: str) -> bool:
    if any(path.startswith(p) for p in EXCLUDE_PREFIXES):
        return False
    return any(path.startswith(p) for p in SCAN_PREFIXES)


def iter_files():
    out = subprocess.check_output(["git", "ls-files"], text=True)
    for rel in out.splitlines():
        if not is_scanned(rel):
            continue
        base = os.path.basename(rel)
        if base.startswith("ARTIFACTS"):
            continue
        if rel.endswith((".yaml", ".yml", ".json", ".tpl")) or base.startswith(("Dockerfile", "Containerfile")):
            yield rel


def normalize_token(token: str) -> str:
    token = token.strip().strip('"').strip("'")
    token = token.split("#", 1)[0].strip()
    token = token.rstrip(",")
    return token


def extract_candidates(line: str):
    # YAML-ish
    m = re.search(r"\b(image|repository)\s*:\s*(.+)$", line)
    if m:
        yield normalize_token(m.group(2))
        return

    # Dockerfile
    m = re.search(r"^\s*FROM\s+([^\s]+)", line)
    if m:
        yield normalize_token(m.group(1))


def is_allowed(ref: str) -> bool:
    if not ref:
        return True
    if ref.startswith(ALLOW_SCHEMES):
        return True
    if ref.startswith(INTERNAL_PREFIX):
        return True
    return False


def is_forbidden(ref: str) -> bool:
    if is_allowed(ref):
        return False
    return ref.startswith(FORBIDDEN_STARTS)


violations = []
for rel in iter_files():
    abs_path = os.path.join(ROOT, rel)
    try:
        with open(abs_path, "r", encoding="utf-8", errors="replace") as f:
            for idx, line in enumerate(f, start=1):
                for cand in extract_candidates(line):
                    if is_forbidden(cand):
                        violations.append((rel, idx, cand))
    except OSError as e:
        violations.append((rel, 0, f"<read error: {e}>") )

if violations:
    print("ERROR: external image references found (must use internal registry)", file=sys.stderr)
    for rel, idx, cand in violations:
        loc = f"{rel}:{idx}" if idx else rel
        print(f"  {loc}: {cand}", file=sys.stderr)
    sys.exit(1)

print("OK: no external image references in scanned manifests/workflows/scripts")
PY
