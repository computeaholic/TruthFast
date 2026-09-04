#!/usr/bin/env bash
# scripts/replay-verify.sh
# Phase 11: Replay verifier (read-only, deterministic)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY_LOG="$REPO_ROOT/platform/deploy/infra/istio/artifacts/VERIFY.log"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

usage() {
  cat <<EOF
Usage: $0 --manifest <manifest.json> --ledger <ledger.csv> --seals <seals_dir> [--append-log]

Manifest (JSON) maps plan_digest -> ordered list of event_ids and expected hashes.
Ledger CSV must contain rows: event_id,payload (payload is JSON string). Seals dir contains per-plan seal files with expected chain hash.

This tool performs read-only hash checks and order checks. It does NOT mutate state.
EOF
}

if [ "$#" -eq 0 ]; then
  usage
  echo "[ADVISORY-FAIL] non-authoritative path" >&2
  exit 2
fi

MANIFEST=""
LEDGER=""
SEALS_DIR=""
APPEND_LOG="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) MANIFEST="$2"; shift 2;;
    --ledger) LEDGER="$2"; shift 2;;
    --seals) SEALS_DIR="$2"; shift 2;;
    --append-log) APPEND_LOG="true"; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; echo "[ADVISORY-FAIL] non-authoritative path" >&2; exit 2;;
  esac
done

if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: manifest not found: $MANIFEST" >&2
  echo "[ADVISORY-FAIL] non-authoritative path" >&2
  exit 2
fi
if [ ! -f "$LEDGER" ]; then
  echo "ERROR: ledger CSV not found: $LEDGER" >&2
  echo "[ADVISORY-FAIL] non-authoritative path" >&2
  exit 2
fi
if [ ! -d "$SEALS_DIR" ]; then
  echo "ERROR: seals dir not found: $SEALS_DIR" >&2
  echo "[ADVISORY-FAIL] non-authoritative path" >&2
  exit 2
fi

# Python helper to perform deterministic checks
set +e
# Prefer repo-local venv python, otherwise fallback to system python3 or python
if [ -x ".venv/bin/python" ]; then
  PY_BIN=".venv/bin/python"
else
  PY_BIN="$(command -v python3 || command -v python || true)"
fi
if [ -z "$PY_BIN" ]; then
  echo "No suitable python interpreter found" >&2
  echo "[ADVISORY-FAIL] non-authoritative path" >&2
  exit 2
fi
PY_OUT=$("$PY_BIN" - <<PY
import json,sys,hashlib
mf=json.load(open('${MANIFEST}'))
# load ledger into dict by event_id preserving order
ledger=[]
with open('${LEDGER}') as f:
    for ln in f:
        ln=ln.strip()
        if not ln: continue
        parts=ln.split(',',1)
        ledger.append({'event_id':parts[0],'payload':parts[1]})

ledger_map={e['event_id']:e for e in ledger}

for plan in mf.get('plans',[]):
    pd=plan['plan_digest']
    events=plan['events']
    # check seals file
    sealsf=f"${SEALS_DIR}/{pd}.seal"
    try:
        seals=open(sealsf).read().strip()
    except FileNotFoundError:
        print(f'MISSING_SEAL:{pd}')
        sys.exit(10)
    # ensure ledger preserves order of events for this plan
    ledger_event_ids=[e['event_id'] for e in ledger]
    indices=[]
    for ev in events:
        eid=ev['event_id']
        if eid not in ledger_map:
            print(f'MISSING_EVENT:{eid}')
            sys.exit(11)
        indices.append(ledger_event_ids.index(eid))
    # indices must be strictly increasing
    if any(indices[i] >= indices[i+1] for i in range(len(indices)-1)):
        print(f'ORDER_MISMATCH:{pd}')
        sys.exit(14)

    # compute chain hash over ordered events
    prev='GENESIS'
    for ev in events:
        eid=ev['event_id']
        payload=ledger_map[eid]['payload']
        # compute entry hash deterministic
        h=hashlib.sha256(f"{prev}:{payload}".encode()).hexdigest()
        if h!=ev['expected_hash']:
            print(f'HASH_MISMATCH:{eid}')
            sys.exit(12)
        prev=h
    # final chain hash must match seal
    if prev!=seals:
        print(f'CHAIN_MISMATCH:{pd}')
        sys.exit(13)
print('PASS')
PY
)
PY_RC=$?
set -e

if [ $PY_RC -eq 0 ] && [ "$PY_OUT" = "PASS" ]; then
  echo "REPLAY PASS"
  if [ "$APPEND_LOG" = "true" ]; then
    echo "--- $TIMESTAMP - replay_verification ---" >> "$VERIFY_LOG"
    echo "PASS: manifest=$MANIFEST ledger=$LEDGER seals=$SEALS_DIR" >> "$VERIFY_LOG"
    echo >> "$VERIFY_LOG"
  fi
  exit 0
else
  # prefer explicit python output if present
  if [ -n "$PY_OUT" ]; then
    echo "REPLAY FAIL: $PY_OUT" >&2
  else
    echo "REPLAY FAIL: rc=$PY_RC" >&2
  fi
  if [ "$APPEND_LOG" = "true" ]; then
    echo "--- $TIMESTAMP - replay_verification ---" >> "$VERIFY_LOG"
    echo "FAIL: $PY_OUT rc=$PY_RC manifest=$MANIFEST ledger=$LEDGER seals=$SEALS_DIR" >> "$VERIFY_LOG"
    echo >> "$VERIFY_LOG"
  fi
  echo "[ADVISORY-FAIL] non-authoritative path" >&2
  exit 2
fi
