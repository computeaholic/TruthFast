#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_PATH="${TRUST_AUTHORITY_STATE_PATH:-$REPO_ROOT/artifacts/trust/trust_authority_state.json}"
METRICS_PATH="${TRUST_AUTHORITY_METRICS_PATH:-$REPO_ROOT/artifacts/trust/trust_authority_metrics.prom}"
COUNTERS_PATH="${TRUST_RECONCILER_COUNTERS_PATH:-$REPO_ROOT/artifacts/trust/reconciler_counters.json}"
REPORT_PATH="${TRUST_DRIFT_REPORT_PATH:-$REPO_ROOT/artifacts/trust/trust_drift_report.json}"

bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null

python3 - "$STATE_PATH" "$REPORT_PATH" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

state_path = Path(sys.argv[1])
report_path = Path(sys.argv[2])

state = json.loads(state_path.read_text(encoding="utf-8"))
active_fp = state.get("active_root_fingerprint", "")
active_serial = state.get("active_root_serial", "")
active_ski = state.get("active_root_ski", "")
active_not_after = state.get("active_root_not_after", "")
publication_lag = int(state.get("publication_age_seconds", 0) or 0)

checks = []
for source in state.get("sources", []):
    name = source.get("name", "unknown")
    present = bool(source.get("present"))
    fp_match = present and source.get("fingerprint_sha256") == active_fp
    serial_match = present and source.get("serial") == active_serial
    ski_match = present and source.get("ski") == active_ski
    expiration_match = present and source.get("not_after") == active_not_after

    checks.append({
        "source": name,
        "present": present,
        "fingerprint_match": fp_match,
        "serial_match": serial_match,
        "ski_match": ski_match,
        "expiration_match": expiration_match,
        "matches_active_root": bool(source.get("matches_active_root")),
        "error": source.get("error", ""),
    })

mismatches = [
    c
    for c in checks
    if (not c["present"])
    or (not c["fingerprint_match"])
    or (not c["serial_match"])
    or (not c["ski_match"])
    or (not c["expiration_match"])
]

status = "PASS" if not mismatches else "FAIL"
report = {
    "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "status": status,
    "summary": "ACTIVE_ROOT == DISTRIBUTED_ROOT" if status == "PASS" else "ACTIVE_ROOT != DISTRIBUTED_ROOT",
    "active_root_fingerprint": active_fp,
    "active_root_serial": active_serial,
    "active_root_ski": active_ski,
    "active_root_not_after": active_not_after,
    "publication_lag_seconds": publication_lag,
    "checks": checks,
    "mismatch_count": len(mismatches),
    "mismatches": mismatches,
}

report_path.parent.mkdir(parents=True, exist_ok=True)
report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(status)
PY

status="$(python3 - "$REPORT_PATH" <<'PY'
import json, sys
print(json.loads(open(sys.argv[1], encoding='utf-8').read()).get('status', 'FAIL'))
PY
)"

if [[ "$status" == "PASS" ]]; then
  echo "[PASS] TRUST_DRIFT: ACTIVE_ROOT == DISTRIBUTED_ROOT"
  echo "[trust-drift] report=$REPORT_PATH"
  exit 0
fi

echo "[FAIL] TRUST_DRIFT: ACTIVE_ROOT != DISTRIBUTED_ROOT"
echo "[trust-drift] report=$REPORT_PATH"
exit 2
