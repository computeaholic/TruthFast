#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/fail.sh
source "$REPO_ROOT/scripts/lib/fail.sh"

if ! command -v kubectl >/dev/null 2>&1; then
  fail_system "kubectl not found in PATH"
fi
if ! command -v python3 >/dev/null 2>&1; then
  fail_system "python3 not found in PATH"
fi

tmp_json="$(mktemp)"
cleanup() {
  rm -f "$tmp_json"
}
trap cleanup EXIT

if ! kubectl -n istio-system get configmap istio-sidecar-injector -o json >"$tmp_json" 2>/dev/null; then
  fail_system "unable to read istio-sidecar-injector configmap"
fi

python3 - "$tmp_json" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

cm_path = Path(sys.argv[1])
raw = json.loads(cm_path.read_text(encoding="utf-8"))

if not isinstance(raw, dict):
    print("[POLICY VIOLATION] invalid istio-sidecar-injector configmap payload", file=sys.stderr)
    raise SystemExit(2)

data = raw.get("data")
if not isinstance(data, dict) or not data:
    print("[POLICY VIOLATION] istio-sidecar-injector configmap has no data", file=sys.stderr)
    raise SystemExit(2)

# Stable source hash over configmap data only.
stable_data = json.dumps(data, sort_keys=True, separators=(",", ":"))
cm_hash = hashlib.sha256(stable_data.encode("utf-8")).hexdigest()

image_refs: set[str] = set()
pat = re.compile(r"([a-z0-9.-]+(?::[0-9]+)?/[a-z0-9._/-]+(?::[^\s\"'@]+)?@sha256:[0-9a-fA-F]{64})")

for _, value in sorted(data.items()):
    if not isinstance(value, str):
        continue
    for m in pat.finditer(value):
        ref = m.group(1).strip().strip('"').strip("'")
        mm = re.match(r"^(?P<name>.+?)(?::(?P<tag>[^/@]+))?@(?P<digest>sha256:[0-9a-fA-F]{64})$", ref)
        if not mm:
            continue
        image_refs.add(f"{mm.group('name')}@{mm.group('digest').lower()}")

if not image_refs:
    print("[POLICY VIOLATION] no digest-pinned injected images found in sidecar injector configmap", file=sys.stderr)
    raise SystemExit(2)

for ref in sorted(image_refs):
    print(f"INJECTED_IMAGE={ref}")
    print("SOURCE=istio-sidecar-injector")
    print(f"HASH={cm_hash}")
PY
