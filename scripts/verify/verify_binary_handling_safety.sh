#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Deterministic fail-closed scanner:
# Forbidden in shell scripts:
# 1) command substitution from secret/configmap data into cert/CA/key/bundle vars
# 2) base64 decode into cert/CA/key/bundle vars
# 3) intentionally omitted: generic echo/printf checks are too noisy for deterministic gating

tmp_hits="$(mktemp)"
trap 'rm -f "$tmp_hits"' EXIT

scan() {
  local pattern="$1"
  rg -n "$pattern" scripts --glob '*.sh' >>"$tmp_hits" || true
}

# var assignment pulling certificate-like data from kubectl jsonpath
scan '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*(cert|certificate|key|bundle|pem|cabundle|ca_bundle|root_cert|rootca|ca_crt|cacert)[A-Za-z0-9_]*[[:space:]]*=.*jsonpath=.*\.data\..*(ca|cert|key|bundle|pem)'

# command substitution that includes base64 decode and cert material hint
scan '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*(cert|certificate|key|bundle|pem|cabundle|ca_bundle|root_cert|rootca|ca_crt|cacert)[A-Za-z0-9_]*[[:space:]]*=.*base64[[:space:]]+-d'

# Exclude this scanner itself from results.
grep -v 'scripts/verify/verify_binary_handling_safety.sh' "$tmp_hits" >"${tmp_hits}.filtered" || true
mv "${tmp_hits}.filtered" "$tmp_hits"

if [[ -s "$tmp_hits" ]]; then
  echo "[FAIL] BINARY_HANDLING_VIOLATION"
  sort -u "$tmp_hits"
  exit 2
fi

echo "[PASS] binary_handling_safety=PASS"
