#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COLLECT_SCRIPT="$REPO_ROOT/scripts/supply_chain/collect_images.sh"
ALLOWED_SYSTEM_IMAGES_PATH="${ALLOWED_SYSTEM_IMAGES_PATH:-$REPO_ROOT/scripts/verify/allowed_system_images.txt}"
PIN_MAP_PATH="${PIN_MAP_PATH:-$REPO_ROOT/platform/config/image_pin_map.json}"
MODE="runtime"

usage() {
  cat <<'EOF'
Usage:
  scripts/verify/verify_collector_completeness.sh [--manifests-only]

Checks collector completeness by comparing canonical expected images from
manifests with canonical runtime images (managed namespaces).

Rules:
  - runtime NOT in expected => FAIL
  - expected NOT in runtime => FAIL (strict equality enforced)

--manifests-only:
  Collect expected image set and validate canonical output shape without
  querying runtime. Intended for CI pre-cluster parity checks.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifests-only)
      MODE="manifests-only"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[FAIL] unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ ! -x "$COLLECT_SCRIPT" ]; then
  echo "[FAIL] collect script missing or not executable: $COLLECT_SCRIPT"
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[FAIL] python3 not found in PATH"
  exit 2
fi

workdir="$(mktemp -d)"
cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT

expected_raw="$workdir/expected_raw.txt"
expected_norm="$workdir/expected.txt"
runtime_raw="$workdir/runtime_raw.txt"
runtime_norm="$workdir/runtime.txt"

"$COLLECT_SCRIPT" --scope managed --output "$expected_raw" >/dev/null

python3 - "$expected_raw" > "$expected_norm" <<'PY'
import re
import sys

path = sys.argv[1]
refs = set()
with open(path, "r", encoding="utf-8") as f:
    for line in f:
        s = line.strip()
        if not s:
            continue
        m = re.match(r"^(?P<name>.+?)(?::(?P<tag>[^/@]+))?@(?P<digest>sha256:[0-9a-fA-F]{64})$", s)
        if not m:
            raise SystemExit(f"[FAIL] expected set contains non-canonical ref: {s}")
        refs.add(f"{m.group('name')}@{m.group('digest').lower()}")

for r in sorted(refs):
    print(r)
PY

LC_ALL=C sort -u -o "$expected_norm" "$expected_norm"

if [ "$MODE" = "manifests-only" ]; then
  count="$(wc -l < "$expected_norm" | tr -d ' ')"
  echo "[PASS] collector dry-run complete: $count canonical manifest image(s)"
  exit 0
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[FAIL] kubectl not found in PATH"
  exit 2
fi
MANAGED_NAMESPACE_RE="${MANAGED_NAMESPACE_RE:-^(threadforge($|-)|threadforge-test$|threadforge-lab$|observability$|istio-system$|spire-system$|argocd$|minio$|tempo$|loki$)}"

runtime_pods_json="$workdir/runtime_pods.json"
kubectl get pods -A -o json > "$runtime_pods_json"

python3 - "$runtime_pods_json" "$MANAGED_NAMESPACE_RE" > "$runtime_raw" <<'PY'
import json, re, sys

pods_path = sys.argv[1]
ns_re = re.compile(sys.argv[2])
doc = json.loads(open(pods_path).read())
images = set()
for pod in doc.get("items", []):
    ns = pod.get("metadata", {}).get("namespace", "")
    if not ns_re.search(ns):
        continue
    spec = pod.get("spec", {})
    for c in (spec.get("containers") or []) + (spec.get("initContainers") or []):
        img = c.get("image", "")
        if img:
            images.add(img)
for img in sorted(images):
    print(img)
PY

python3 - "$runtime_raw" "$PIN_MAP_PATH" > "$runtime_norm" <<'PY'
import json
import pathlib
import re
import sys

path = sys.argv[1]
pin_map_path = sys.argv[2]

pin_map = {}
try:
    pin_map = json.loads(pathlib.Path(pin_map_path).read_text())
except Exception:
    pass

refs = set()
with open(path, "r", encoding="utf-8") as f:
    for line in f:
        s = line.strip()
        if not s:
            continue
        # If this is an approved tag alias, resolve it to its digest-pinned form.
        if s in pin_map:
            s = pin_map[s]
        m = re.match(r"^(?P<name>.+?)(?::(?P<tag>[^/@]+))?@(?P<digest>sha256:[0-9a-fA-F]{64})$", s)
        if not m:
            raise SystemExit(f"[FAIL] runtime image is not digest pinned: {s}")
        refs.add(f"{m.group('name')}@{m.group('digest').lower()}")

for r in sorted(refs):
    print(r)
PY

LC_ALL=C sort -u -o "$runtime_norm" "$runtime_norm"

runtime_not_expected="$workdir/runtime_not_expected.txt"
expected_not_runtime="$workdir/expected_not_runtime.txt"

LC_ALL=C comm -23 "$runtime_norm" "$expected_norm" > "$runtime_not_expected"
LC_ALL=C comm -13 "$runtime_norm" "$expected_norm" > "$expected_not_runtime"

if [ -f "$ALLOWED_SYSTEM_IMAGES_PATH" ] && [ -s "$runtime_not_expected" ]; then
  python3 - "$runtime_not_expected" "$ALLOWED_SYSTEM_IMAGES_PATH" > "$workdir/runtime_not_expected_filtered.txt" <<'PY'
import re
import sys

runtime_path = sys.argv[1]
allowed_path = sys.argv[2]

def canonical(ref: str) -> str | None:
  m = re.match(r"^(?P<name>.+?)(?::(?P<tag>[^/@]+))?@(?P<digest>sha256:[0-9a-fA-F]{64})$", ref.strip())
  if not m:
    return None
  return f"{m.group('name')}@{m.group('digest').lower()}"

allowed = set()
for line in open(allowed_path, "r", encoding="utf-8"):
  s = line.split("#", 1)[0].strip()
  if not s:
    continue
  c = canonical(s)
  if c:
    allowed.add(c)

for line in open(runtime_path, "r", encoding="utf-8"):
  s = line.strip()
  if not s:
    continue
  c = canonical(s)
  if c and c in allowed:
    continue
  print(s)
PY
  mv "$workdir/runtime_not_expected_filtered.txt" "$runtime_not_expected"
fi

if [ -s "$runtime_not_expected" ]; then
  echo "[FAIL] CONTRACT_VIOLATION: runtime != manifest — runtime has image(s) missing from collected manifest set:"
  sed 's/^/  - /' "$runtime_not_expected"
  exit 2
fi

if [ -s "$expected_not_runtime" ]; then
  echo "MANIFEST_ONLY_IMAGES_START"
  sed 's/^/  - /' "$expected_not_runtime"
  echo "MANIFEST_ONLY_IMAGES_END"
fi

echo "[PASS] collector completeness validated (runtime is contained in manifest set)"
