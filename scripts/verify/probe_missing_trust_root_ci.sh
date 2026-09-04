#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

OUT_LOG="${1:-artifacts/ci_hostile_review/missing-trust-root-ci.log}"
mkdir -p "$(dirname "$OUT_LOG")" artifacts/ci_hostile_review artifacts/trust

exec > >(tee "$OUT_LOG") 2>&1

echo "[probe] missing-trust-root hostile validation"

TRUST_ROOT="artifacts/trust/root.pem"
BACKUP="artifacts/trust/root.pem.bak.missing-probe"

if [[ ! -s "$TRUST_ROOT" ]]; then
  TRUST_ROOT_PHASE=capture bash scripts/verify/verify_trust_root_immutability.sh >/dev/null
fi

if [[ ! -s "$TRUST_ROOT" ]]; then
  echo "[FAIL] unable to establish baseline trust root artifact before probe"
  exit 2
fi

cp "$TRUST_ROOT" "$BACKUP"
rm -f "$TRUST_ROOT"

set +e
probe_out="$(TRUST_ROOT_PHASE=drift bash scripts/verify/verify_trust_root_immutability.sh 2>&1)"
rc=$?
set -e

mv "$BACKUP" "$TRUST_ROOT"

if [[ "$rc" -eq 0 ]]; then
  echo "$probe_out"
  echo "[FAIL] drift verification unexpectedly passed without trust-root artifact"
  exit 2
fi

if ! printf '%s\n' "$probe_out" | grep -q 'TRUST_ROOT_MISSING'; then
  echo "$probe_out"
  echo "[FAIL] missing-trust-root probe failed without TRUST_ROOT_MISSING classification"
  exit 2
fi

echo "$probe_out"
python3 - <<'PY'
import json
from pathlib import Path

out = Path('artifacts/ci_hostile_review/missing-trust-root.failure.json')
out.write_text(json.dumps({
  'fail_class': 'TRUST_ROOT_MISSING',
  'component': 'verify_trust_root_immutability',
  'status': 'EXPECTED_FAIL_CLOSED'
}, indent=2) + '\n')
print('[PASS] TRUST_ROOT_MISSING classified fail-closed as expected')
PY
