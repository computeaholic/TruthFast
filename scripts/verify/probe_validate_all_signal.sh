#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

SIGNAL_NAME="${1:-TERM}"
TARGET_STEP="${2:-infra-bootstrap}"
OUT_LOG="${3:-artifacts/ci_hostile_review/signal-${SIGNAL_NAME,,}-${TARGET_STEP}.log}"

mkdir -p "$(dirname "$OUT_LOG")" artifacts/mode_runs artifacts/ci_hostile_review
rm -f artifacts/mode_runs/validate-all.failure.json

bash scripts/verify/validate_all.sh >"$OUT_LOG" 2>&1 &
runner_pid="$!"

found_marker=0
for _ in $(seq 1 1200); do
  if grep -q "^\[STEP\] ${TARGET_STEP}$" "$OUT_LOG" 2>/dev/null; then
    found_marker=1
    break
  fi
  if ! kill -0 "$runner_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if [[ "$found_marker" -ne 1 ]]; then
  echo "[FAIL] did not observe target step marker: $TARGET_STEP" | tee -a "$OUT_LOG"
  wait "$runner_pid" || true
  exit 2
fi

kill -s "$SIGNAL_NAME" "$runner_pid" >/dev/null 2>&1 || true
wait "$runner_pid" || true

if [[ ! -s artifacts/mode_runs/validate-all.failure.json ]]; then
  echo "[FAIL] missing validate-all failure artifact" | tee -a "$OUT_LOG"
  exit 2
fi

cp artifacts/mode_runs/validate-all.failure.json "artifacts/ci_hostile_review/signal-${SIGNAL_NAME,,}-${TARGET_STEP}.failure.json"

python3 - <<'PY' "artifacts/ci_hostile_review/signal-${SIGNAL_NAME,,}-${TARGET_STEP}.failure.json" "$SIGNAL_NAME" "$TARGET_STEP"
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
signal = sys.argv[2]
step = sys.argv[3]
doc = json.loads(path.read_text())

assert doc.get("fail_class") == "SIGNAL_INTERRUPTED", f"unexpected fail_class: {doc.get('fail_class')}"
assert str(doc.get("signal_type", "")).upper() in {signal.upper(), str(doc.get("signal", "")).upper()}, "signal fields did not capture injected signal"
assert str(doc.get("active_phase", "")).strip() == step, f"active_phase mismatch: {doc.get('active_phase')}"
assert str(doc.get("active_step", "")).strip() == step, f"active_step mismatch: {doc.get('active_step')}"
assert str(doc.get("artifact_state", "")).strip() != "", "artifact_state missing"
assert str(doc.get("cleanup_state", "")).strip() != "", "cleanup_state missing"
print("[PASS] signal interruption artifact classification is explicit")
PY
