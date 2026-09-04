#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_PATH="${TRUST_AUTHORITY_STATE_PATH:-$REPO_ROOT/artifacts/trust/trust_authority_state.json}"
ALERT_PATH="${TRUST_EXPIRATION_ALERT_PATH:-$REPO_ROOT/artifacts/trust/trust_expiration_alert.json}"

bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null

python3 - "$STATE_PATH" "$ALERT_PATH" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

state_path = Path(sys.argv[1])
alert_path = Path(sys.argv[2])
state = json.loads(state_path.read_text(encoding="utf-8"))
remaining = int(state.get("root_expiration_seconds", 0) or 0)

if remaining < 3600:
    level = "EMERGENCY"
elif remaining < 12 * 3600:
    level = "CRITICAL"
elif remaining < 24 * 3600:
    level = "WARNING"
else:
    level = "OK"

alert_doc = {
    "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "status": "PASS" if level == "OK" else "FAIL",
    "alert_level": level,
    "remaining_seconds": remaining,
    "active_root_fingerprint": state.get("active_root_fingerprint", ""),
    "active_root_not_after": state.get("active_root_not_after", ""),
    "thresholds_seconds": {
        "warning": 24 * 3600,
        "critical": 12 * 3600,
        "emergency": 3600,
    },
}

alert_path.parent.mkdir(parents=True, exist_ok=True)
alert_path.write_text(json.dumps(alert_doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(level)
PY

level="$(python3 - "$ALERT_PATH" <<'PY'
import json, sys
print(json.loads(open(sys.argv[1], encoding='utf-8').read()).get('alert_level', 'UNKNOWN'))
PY
)"

echo "[trust-expiration] level=$level"
echo "[trust-expiration] alert=$ALERT_PATH"
