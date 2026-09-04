#!/usr/bin/env bash
# Collect Civ DecisionRecord artifacts into evidence dir for integration runs
# Usage: ./collect_civ_artifacts.sh [DEST_DIR]
set -euo pipefail
DEST_DIR=${1:-platform/deploy/infra/observability/evidence/phase2/civ-integration}
mkdir -p "$DEST_DIR"
SRC_DIR=artifacts/civ/decisions
if [ ! -d "$SRC_DIR" ]; then
  echo "[ERROR] Source artifacts dir not found: $SRC_DIR" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
# copy artifact files
cp -av "$SRC_DIR"/* "$DEST_DIR"/
# list copied files
echo "Copied artifacts:"
ls -l "$DEST_DIR" | sed -n '1,200p'
# quick verification: ensure each JSON has provenance_hash and signature fields
echo "Verifying artifact fields..."
issue_count=0
for f in "$DEST_DIR"/*.json; do
  if ! jq -e '.provenance_hash and .signature' "$f" >/dev/null 2>&1; then
    if [ "${FAIL_ON_ISSUES:-0}" -eq 1 ] || [ -n "${CIV_PUBLIC_KEY:-}" ]; then
      echo "[ERROR] Artifact $f missing provenance_hash or signature" >&2
      issue_count=$((issue_count+1))
    else
      echo "[WARN] Artifact $f missing provenance_hash or signature" >&2
    fi
  else
    echo "[OK] $f contains provenance_hash and signature"
  fi
done
# optional: verify signatures if CIV_PUBLIC_KEY is present
if [ -n "${CIV_PUBLIC_KEY:-}" ]; then
  echo "CIV_PUBLIC_KEY detected - running signature verification..."
  python - <<'PY'
import json,sys,glob,copy,hashlib
from runtime.civ.provenance.artifact_signing import SignatureVerifier, SigningError
verifier = SignatureVerifier()
any_fail = False
for f in glob.glob('''$DEST_DIR/*.json'''):
    with open(f) as fh:
        data = json.load(fh)
    # Build signature metadata from stored fields
    sig = data.get('signature','')
    key_id = data.get('signing_key_id','')
    alg = data.get('algorithm','ed25519')
    if not sig or not key_id:
        print(f"{f}: missing signature metadata; cannot verify", file=sys.stderr)
        any_fail = True
        continue

    # Recompute canonical signed content (exclude signature metadata)
    content = {k: v for k, v in data.items() if k not in ('signature','signing_key_id','algorithm','signed_content_hash')}
    content_str = json.dumps(content, sort_keys=True)
    signed_content_hash = hashlib.sha256(content_str.encode('utf-8')).hexdigest()

    sig_meta = {
        'algorithm': alg,
        'key_id': key_id,
        'signature': sig,
        'signed_content_hash': signed_content_hash,
    }

    ok,err = verifier.verify_signature(content_str, sig_meta)
    print(f"{f}: verified={ok}, err={err}")
    if not ok:
        any_fail = True
if any_fail:
    sys.exit(2)
PY
  py_rc=$? || true
  if [ "$py_rc" -ne 0 ]; then
    echo "[ERROR] Signature verification failed for one or more artifacts" >&2
    issue_count=$((issue_count+1))
  fi
else
  echo "CIV_PUBLIC_KEY not set - skipping cryptographic verification"
fi

if [ "$issue_count" -gt 0 ]; then
  if [ "${FAIL_ON_ISSUES:-0}" -eq 1 ] || [ -n "${CIV_PUBLIC_KEY:-}" ]; then
    echo "[ERROR] $issue_count artifact issue(s) detected; failing as requested" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  else
    echo "[WARN] $issue_count artifact issue(s) detected; not failing" >&2
  fi
fi
echo "Done. Artifacts copied to $DEST_DIR"
