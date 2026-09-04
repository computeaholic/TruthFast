#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

# verify_output_clean.sh — Proof output cleanliness enforcement.
#
# Contract:
#   - No [WARN] lines in any phase log
#   - No bare "Warning:" / "warning:" from kubectl, kyverno, cosign, helm
#   - No [SKIP] or OPTIONAL markers in any phase log
#   - No skip/skipping/skipped semantics (implicit bypass language)
#   - No transient/retry/fallback/eventual/warming language in any phase log
#   - No attempt/trying/may/could language in any phase log
#   - No subsequent [PASS] after the first [FAIL] within the same phase log
#
# Exit 0 = PROOF_OUTPUT_CLEAN
# Exit 2 = PURITY_VIOLATION (noise or forbidden markers detected)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_DIR="${PROOF_LOG_DIR:-$REPO_ROOT/artifacts/proof/latest}"

VIOLATIONS=0
VIOLATION_LINES=()

PHASE_LOGS=(
  "$LOG_DIR/bootstrap.log"
  "$LOG_DIR/identity.log"
  "$LOG_DIR/envoy_identity.log"
  "$LOG_DIR/cluster_integrity.log"
  "$LOG_DIR/observability_prereq.log"
  "$LOG_DIR/verify.log"
  "$LOG_DIR/observe.log"
)

check_log() {
  local log="$1"
  local name
  name="$(basename "$log")"

  local warn_hits
  warn_hits="$(grep -cE '^\[WARN\]' "$log" 2>/dev/null || true)"
  if [ "${warn_hits:-0}" -gt 0 ]; then
    echo "[FAIL] $name: $warn_hits [WARN] line(s) detected"
    while IFS= read -r line; do
      VIOLATION_LINES+=("$name: $line")
    done < <(grep -E '^\[WARN\]' "$log" 2>/dev/null || true)
    VIOLATIONS=$((VIOLATIONS + 1))
  fi

  # Bare "Warning:" from kubectl, kyverno, cosign, helm, and similar tools
  local bare_warn_hits
  bare_warn_hits="$(grep -E '(^|[[:space:]])Warning:[[:space:]]|^warning:[[:space:]]' "$log" 2>/dev/null \
    | grep -v 'kubectl.kubernetes.io/last-applied-configuration annotation' \
    | grep -vE '^\[FAIL\] [^:]+: [0-9]+ bare Warning: line\(s\) detected$' \
    | wc -l | tr -d ' ' || true)"
  if [ "${bare_warn_hits:-0}" -gt 0 ]; then
    echo "[FAIL] $name: $bare_warn_hits bare Warning: line(s) detected"
    while IFS= read -r line; do
      VIOLATION_LINES+=("$name: $line")
    done < <(grep -E '(^|[[:space:]])Warning:[[:space:]]|^warning:[[:space:]]' "$log" 2>/dev/null \
      | grep -v 'kubectl.kubernetes.io/last-applied-configuration annotation' \
      | grep -vE '^\[FAIL\] [^:]+: [0-9]+ bare Warning: line\(s\) detected$' || true)
    VIOLATIONS=$((VIOLATIONS + 1))
  fi

  local skip_hits
  skip_hits="$(grep -cE '\[SKIP\]' "$log" 2>/dev/null || true)"
  if [ "${skip_hits:-0}" -gt 0 ]; then
    echo "[FAIL] $name: $skip_hits [SKIP] marker(s) detected"
    while IFS= read -r line; do
      VIOLATION_LINES+=("$name: $line")
    done < <(grep -E '\[SKIP\]' "$log" 2>/dev/null || true)
    VIOLATIONS=$((VIOLATIONS + 1))
  fi

  local optional_hits
  optional_hits="$(grep -cE '\[OPTIONAL\]' "$log" 2>/dev/null || true)"
  if [ "${optional_hits:-0}" -gt 0 ]; then
    echo "[FAIL] $name: $optional_hits [OPTIONAL] marker(s) detected"
    while IFS= read -r line; do
      VIOLATION_LINES+=("$name: $line")
    done < <(grep -E '\[OPTIONAL\]' "$log" 2>/dev/null || true)
    VIOLATIONS=$((VIOLATIONS + 1))
  fi

  # Skip/bypass language: skipping, skip, skipped (not inside "[FAIL] ... skip markers")
  local skip_lang_hits
  skip_lang_hits="$(grep -cEi '\bskipping\b|\bskipped\b' "$log" 2>/dev/null || true)"
  if [ "${skip_lang_hits:-0}" -gt 0 ]; then
    # Whitelist: structured [FAIL] lines about skip markers being forbidden (the scanner itself)
    local real_skip_lang_hits
    real_skip_lang_hits="$(grep -Ei '\bskipping\b|\bskipped\b' "$log" 2>/dev/null \
      | grep -cvE '^\[FAIL\].*skip marker|skip markers are forbidden' || true)"
    if [ "${real_skip_lang_hits:-0}" -gt 0 ]; then
      echo "[FAIL] $name: $real_skip_lang_hits skip-semantics line(s) detected"
      while IFS= read -r line; do
        VIOLATION_LINES+=("$name: $line")
      done < <(grep -Ei '\bskipping\b|\bskipped\b' "$log" 2>/dev/null \
        | grep -vE '^\[FAIL\].*skip marker|skip markers are forbidden' || true)
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  fi

  local noise_hits
  noise_hits="$(grep -cE '^\[(WARN|INFO)\].*\b(retry|transient|fallback|eventual|warming|attempt|trying|may|could)\b' "$log" 2>/dev/null || true)"
  if [ "${noise_hits:-0}" -gt 0 ]; then
    echo "[FAIL] $name: $noise_hits ambiguous/transient language line(s) detected"
    while IFS= read -r line; do
      VIOLATION_LINES+=("$name: $line")
    done < <(grep -E '^\[(WARN|INFO)\].*\b(retry|transient|fallback|eventual|warming|attempt|trying|may|could)\b' "$log" 2>/dev/null || true)
    VIOLATIONS=$((VIOLATIONS + 1))
  fi

  # [INFO] brackets — not part of the proof contract vocabulary
  local info_hits
  info_hits="$(grep -cE '^\[INFO\]' "$log" 2>/dev/null || true)"
  if [ "${info_hits:-0}" -gt 0 ]; then
    echo "[FAIL] $name: $info_hits [INFO] line(s) detected — only [PASS]/[FAIL]/[PHASE] allowed"
    while IFS= read -r line; do
      VIOLATION_LINES+=("$name: $line")
    done < <(grep -E '^\[INFO\]' "$log" 2>/dev/null || true)
    VIOLATIONS=$((VIOLATIONS + 1))
  fi

  # Bare non-contract phrases: "Checking...", "Waiting..." as standalone lines
  local bare_noise_hits
  bare_noise_hits="$(grep -cE '^(Checking|Waiting|Looking|Verifying|Testing)\b' "$log" 2>/dev/null || true)"
  if [ "${bare_noise_hits:-0}" -gt 0 ]; then
    echo "[FAIL] $name: $bare_noise_hits bare diagnostic phrase(s) detected (non-contract output)"
    while IFS= read -r line; do
      VIOLATION_LINES+=("$name: $line")
    done < <(grep -E '^(Checking|Waiting|Looking|Verifying|Testing)\b' "$log" 2>/dev/null || true)
    VIOLATIONS=$((VIOLATIONS + 1))
  fi

  # Contradictory PASS: once a phase emits [FAIL], it must not emit [PASS] later.
  local contradictory_passes contra_hits
  contradictory_passes="$(python3 - "$log" <<'PY' 2>/dev/null || true
import sys
from pathlib import Path

hits = []
seen_fail = False
for line_no, raw in enumerate(Path(sys.argv[1]).read_text().splitlines(), start=1):
    line = raw.strip()
    if line.startswith('[FAIL]'):
        seen_fail = True
    elif seen_fail and line.startswith('[PASS]'):
        hits.append(f"line {line_no}: {raw}")

print("\n".join(hits))
PY
)"
  if [ -n "$contradictory_passes" ]; then
    contra_hits="$(printf '%s\n' "$contradictory_passes" | sed '/^$/d' | wc -l | tr -d ' ')"
    echo "[FAIL] $name: PURITY_VIOLATION: contradictory PASS after FAIL"
    VIOLATION_LINES+=("$name: PURITY_VIOLATION: contradictory PASS after FAIL")
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      VIOLATION_LINES+=("$name: $line")
    done <<< "$contradictory_passes"
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
}

if [ ! -d "$LOG_DIR" ]; then
  echo "[FAIL] proof log directory not found: $LOG_DIR"
  exit 2
fi

for log in "${PHASE_LOGS[@]}"; do
  if [ -f "$log" ]; then
    check_log "$log"
  fi
done

if [ "$VIOLATIONS" -gt 0 ]; then
  echo ""
  echo "PURITY_VIOLATION:"
  for line in "${VIOLATION_LINES[@]}"; do
    echo "  $line"
  done
  echo ""
  echo "[FAIL] proof output contains $VIOLATIONS purity violation(s)"
  exit 2
fi

echo "[PASS] proof output is clean: no [WARN], no Warning:, no [SKIP], no skip semantics, no OPTIONAL, no ambiguous language, no contradictory PASS after FAIL"
echo "PROOF_PURITY_CONFIRMED"
exit 0
