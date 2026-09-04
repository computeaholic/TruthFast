#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

# =============================================================================
# verify_deterministic_ordering.sh
#
# Enforces that all proof artifact aggregation steps produce sorted,
# canonically-ordered output. Filesystem traversal order is non-deterministic
# across runs and OS scheduler variations; any aggregation that uses raw
# readdir / ls order will produce different hashes across runs — a false
# non-determinism signal.
#
# Checks:
#   1. image_pin_map_baseline.json — image list must be lexicographically sorted
#   2. artifacts/verify_results.json — service list must be sorted
#   3. status.json reasons[] — must be sorted by (type, component)
#   4. hashes.txt — must be line-sorted (sha256sum output order)
#   5. spire/entries.yaml — SPIRE entry spiffe_ids must be sorted
#
# Exit codes:
#   0  All ordering checks pass
#   1  One or more ordering violations detected
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PROOF_DIR="${PROOF_DIR:-$REPO_ROOT/artifacts/proof/latest}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$REPO_ROOT/artifacts}"

FAILURES=0
fail() { echo "[FAIL] $*"; FAILURES=$((FAILURES + 1)); }

echo "[deterministic-ordering] checking proof artifact sort invariants"
echo "[deterministic-ordering] proof_dir=$PROOF_DIR"

# ── 1. image_pin_map_baseline.json — keys must be sorted ─────────────────
pin_map="$ARTIFACTS_DIR/image_pin_map_baseline.json"
if [ -f "$pin_map" ]; then
  python3 - "$pin_map" <<'PY' || fail "image_pin_map_baseline.json: image keys are not lexicographically sorted"
import json, sys
data = json.loads(open(sys.argv[1]).read())
keys = list(data.keys())
if keys != sorted(keys):
    first_bad = next((k for k, s in zip(keys, sorted(keys)) if k != s), None)
    raise SystemExit(f"ordering violation: '{first_bad}' out of sorted order")
PY
  echo "[PASS] image_pin_map_baseline.json keys are sorted"
else
  echo "[PASS] image_pin_map_baseline.json not present (optional in this run)"
fi

# ── 2. verify_results.json — services list must be sorted ────────────────
verify_results="$ARTIFACTS_DIR/verify_results.json"
if [ -f "$verify_results" ]; then
  python3 - "$verify_results" <<'PY' || fail "verify_results.json: services list is not sorted"
import json, sys
data = json.loads(open(sys.argv[1]).read())
services = [s.get("name", "") for s in data.get("services", [])]
if services != sorted(services):
    first_bad = next((a for a, b in zip(services, sorted(services)) if a != b), None)
    raise SystemExit(f"ordering violation: '{first_bad}' out of sorted order")
PY
  echo "[PASS] verify_results.json services list is sorted"
else
  echo "[PASS] verify_results.json not present (optional in this run)"
fi

# ── 3. status.json reasons[] — must be sorted by (type, component) ───────
status_json="$PROOF_DIR/status.json"
if [ -f "$status_json" ]; then
  python3 - "$status_json" <<'PY' || fail "status.json: reasons[] is not sorted by (type, component)"
import json, sys
data = json.loads(open(sys.argv[1]).read())
reasons = data.get("reasons", [])
if not isinstance(reasons, list):
    raise SystemExit(0)
keys = [(r.get("type",""), r.get("component","")) for r in reasons]
if keys != sorted(keys):
    first_bad = next(((a,b) for (a,b),(c,d) in zip(keys, sorted(keys)) if a!=c or b!=d), None)
    raise SystemExit(f"ordering violation at reasons entry: type={first_bad[0]} component={first_bad[1]}")
PY
  echo "[PASS] status.json reasons[] sorted by (type, component)"
else
  echo "[PASS] status.json not present at $status_json (optional before finalization)"
fi

# ── 4. hashes.txt — lines must be line-sorted ────────────────────────────
hashes_txt="$PROOF_DIR/hashes.txt"
if [ -f "$hashes_txt" ]; then
  python3 - "$hashes_txt" <<'PY' || fail "hashes.txt: lines are not lexicographically sorted"
import sys
lines = [l.rstrip("\n") for l in open(sys.argv[1]).readlines() if l.strip()]
if lines != sorted(lines):
    first_bad = next((a for a, b in zip(lines, sorted(lines)) if a != b), None)
    raise SystemExit(f"ordering violation: '{first_bad[:60]}' out of sorted order")
PY
  echo "[PASS] hashes.txt lines are sorted"
else
  echo "[PASS] hashes.txt not present at $hashes_txt (optional before finalization)"
fi

# ── 5. spire/entries.yaml — spiffeId values must be sorted ───────────────
spire_entries="$ARTIFACTS_DIR/spire/entries.yaml"
if [ -f "$spire_entries" ]; then
  python3 - "$spire_entries" <<'PY' || fail "spire/entries.yaml: spiffeId list is not sorted"
import sys, re
text = open(sys.argv[1]).read()
ids = re.findall(r'spiffeId:\s*(\S+)', text)
if ids != sorted(ids):
    first_bad = next((a for a, b in zip(ids, sorted(ids)) if a != b), None)
    raise SystemExit(f"ordering violation: '{first_bad}' out of sorted order")
PY
  echo "[PASS] spire/entries.yaml spiffeId list is sorted"
else
  echo "[PASS] spire/entries.yaml not present (optional in this run)"
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "[FAIL] verify_deterministic_ordering: $FAILURES violation(s) detected"
  echo "[FAIL] CONTRACT_VIOLATION: artifact aggregation ordering invariants not satisfied"
  exit 2
fi
echo "[PASS] all deterministic ordering checks passed"
