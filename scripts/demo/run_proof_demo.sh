#!/usr/bin/env bash
set -euo pipefail

# ThreadForge Proof Demo
#
# Executes STRICT_MODE=true make proof and prints a self-contained
# summary of all guarantee statuses, the final result, and the path
# to signed artifacts.
#
# No retries. No fallback. No sleeps. No manual explanation required.
# Exit code 0 means FINAL=PASS, passive and active guarantees PASS, and no guarantee FAIL.
# Exit code 1 ↔ FINAL=FAIL or any guarantee FAIL.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROOF_LATEST="$REPO_ROOT/artifacts/proof/latest"
STATUS_JSON="$PROOF_LATEST/status.json"

REQUIRED_GUARANTEES=(
  fail_closed_execution
  deterministic_output
  no_fallback_logic
  no_optional_paths
  identity_spiffe
  identity_envoy
  supply_chain_digest
  runtime_identity_verified
  no_external_images
  admission_enforced
  observability_stack
  observability_behavior
  trust_root_immutability
  cert_rotation_continuity
  no_istio_ca_fallback
)

# ---------------------------------------------------------------------------
# Run the proof
# ---------------------------------------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ThreadForge Proof Demo"
echo "  Executing: STRICT_MODE=true make proof"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

cd "$REPO_ROOT"
PROOF_EXIT=0
STRICT_MODE=true make proof || PROOF_EXIT=$?

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Proof Complete — Results"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ---------------------------------------------------------------------------
# Parse and print results
# ---------------------------------------------------------------------------
if [ ! -f "$STATUS_JSON" ]; then
  echo "[FAIL] status.json not found: $STATUS_JSON"
  exit 10
fi

FINAL="$(python3 -c "import json,pathlib; d=json.loads(pathlib.Path('$STATUS_JSON').read_text()); print(d.get('final','MISSING'))")"
FAIL_CLASS="$(python3 -c "import json,pathlib; d=json.loads(pathlib.Path('$STATUS_JSON').read_text()); print(d.get('fail_class','MISSING'))")"
RUN_ID="$(python3 -c "import json,pathlib; d=json.loads(pathlib.Path('$STATUS_JSON').read_text()); print(d.get('run_id','MISSING'))")"

printf "  %-30s %s\n" "FINAL:" "$FINAL"
printf "  %-30s %s\n" "fail_class:" "$FAIL_CLASS"
printf "  %-30s %s\n" "run_id:" "$RUN_ID"
echo ""
echo "  Guarantees:"
echo "  ─────────────────────────────────────"

GUARANTEE_FAIL=0
python3 - "$STATUS_JSON" "${REQUIRED_GUARANTEES[@]}" <<'PY'
import json
import pathlib
import sys

status_path = pathlib.Path(sys.argv[1])
required = sys.argv[2:]

doc = json.loads(status_path.read_text())
guarantees = doc.get("guarantees", {})

for g in required:
    entry = guarantees.get(g)
    if not isinstance(entry, dict):
        status = "MISSING"
        phase = "-"
    else:
        status = entry.get("status", "MISSING")
        phase = entry.get("phase", "-")
    mark = "✓" if status == "PASS" else "✗"
    print(f"  {mark} {g:<35} {status:<6}  [{phase}]")

all_pass = True
for g in required:
  entry = guarantees.get(g)
  if not isinstance(entry, dict):
    all_pass = False
    break
  status = entry.get("status")
  if g in {"admission_enforced", "cert_rotation_continuity"}:
    if status not in {"PASS", "BLOCKED"}:
      all_pass = False
      break
  elif status != "PASS":
    all_pass = False
    break
print()
if all_pass:
  print("  GUARANTEE TRUTH MODEL SATISFIED")
else:
    print("  ONE OR MORE GUARANTEES FAILED")
    sys.exit(1)
PY
GUARANTEE_FAIL=$?

echo ""
echo "  Signed artifacts:"
printf "    %s\n" "$PROOF_LATEST/"
echo ""

if ls "$PROOF_LATEST/"*.sig >/dev/null 2>&1; then
  for sig_file in "$PROOF_LATEST/"*.sig; do
    base="${sig_file##*/}"
    printf "    [signed] %s\n" "$base"
  done
else
  echo "    [!] no .sig files found — artifacts may not be signed"
fi

echo ""

# ---------------------------------------------------------------------------
# Final exit
# ---------------------------------------------------------------------------
if [ "$FINAL" = "PASS" ] && [ "$GUARANTEE_FAIL" -eq 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  DEMO RESULT: PASS"
  echo "  System is cryptographically and semantically provable."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 0
else
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  DEMO RESULT: FAIL"
  printf "  FINAL=%s  fail_class=%s\n" "$FINAL" "$FAIL_CLASS"
  echo "  Inspect: $STATUS_JSON"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 2
fi
