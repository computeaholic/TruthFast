#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_PATH="${TRUST_AUTHORITY_STATE_PATH:-$REPO_ROOT/artifacts/trust/trust_authority_state.json}"
METRICS_PATH="${TRUST_AUTHORITY_METRICS_PATH:-$REPO_ROOT/artifacts/trust/trust_authority_metrics.prom}"
COUNTERS_PATH="${TRUST_RECONCILER_COUNTERS_PATH:-$REPO_ROOT/artifacts/trust/reconciler_counters.json}"

mkdir -p "$(dirname "$STATE_PATH")"

python3 "$REPO_ROOT/scripts/trust/trust_authority.py" export-state \
  --state-path "$STATE_PATH" \
  --metrics-path "$METRICS_PATH" \
  --counters-path "$COUNTERS_PATH"

python3 - "$STATE_PATH" <<'PY'
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

state_path = Path(sys.argv[1])
state = json.loads(state_path.read_text(encoding="utf-8"))

required = (
    "active_root_serial",
    "active_root_fingerprint",
    "active_root_pem",
    "generated_at",
    "source_observed_at",
)
missing = [name for name in required if not str(state.get(name, "")).strip()]
if missing:
    raise SystemExit(f"[FAIL] TRUST_AUTHORITY_STATE_INVALID: missing fields: {', '.join(missing)}")

pem = str(state["active_root_pem"]).strip()
count = len(re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", pem))
if count != 1:
    raise SystemExit("[FAIL] TRUST_AUTHORITY_STATE_INVALID: active_root_pem must contain exactly one certificate")

with tempfile.NamedTemporaryFile("w", delete=False) as handle:
    handle.write(pem)
    cert_path = handle.name
try:
    proc = subprocess.run(
        ["openssl", "x509", "-in", cert_path, "-noout", "-serial"],
        capture_output=True,
        text=True,
        check=False,
    )
finally:
    Path(cert_path).unlink(missing_ok=True)
if proc.returncode != 0:
    raise SystemExit(proc.stderr.strip() or proc.stdout.strip() or "[FAIL] TRUST_AUTHORITY_STATE_INVALID: active_root_pem is not valid PEM")
serial = proc.stdout.strip().split("=", 1)[-1].strip().lower().lstrip("0") or "0"
if serial != str(state["active_root_serial"]).strip().lower().lstrip("0"):
    raise SystemExit("[FAIL] TRUST_AUTHORITY_STATE_INVALID: active_root_pem does not match active_root_serial")
PY

echo "[trust-authority] state=$STATE_PATH"
echo "[trust-authority] metrics=$METRICS_PATH"
