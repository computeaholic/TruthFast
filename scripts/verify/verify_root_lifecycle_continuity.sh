#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export VERIFY_TYPE=ACTIVE
TMP_DIR="$(mktemp -d)"
SPIRE_BUNDLE_TMP="$TMP_DIR/spire_bundle.pem"
SPIRE_LOGS_TMP="$TMP_DIR/spire_lifecycle.log"
SPIRE_AUTHORITY_STATE_TMP="$TMP_DIR/spire_authority_state.json"
TRUST_AUTHORITY_STATE_FILE="${TRUST_AUTHORITY_STATE_FILE:-$REPO_ROOT/artifacts/trust/trust_authority_state.json}"
SPIRE_CSR_CA_TMP="$TMP_DIR/spire_csr_ca.pem"
SPIRE_NAMESPACE="${SPIRE_NAMESPACE:-spire-system}"
SPIRE_SERVER_POD="${SPIRE_SERVER_POD:-}"
SPIRE_SERVER_BIN="${SPIRE_SERVER_BIN:-/opt/spire/bin/spire-server}"
SPIRE_SOCKET="${SPIRE_SOCKET:-/run/spire/private/spire-server.sock}"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Fetch authoritative SPIRE bundle via spire-server socket
if [[ -z "$SPIRE_SERVER_POD" ]]; then
  SPIRE_SERVER_POD="$(select_active_spire_server_pod "$SPIRE_NAMESPACE" || true)"
fi
if [[ -z "$SPIRE_SERVER_POD" ]]; then
  echo "[verify_root_lifecycle] unable to resolve active SPIRE server pod" >&2
  exit 2
fi
kubectl -n "$SPIRE_NAMESPACE" exec "$SPIRE_SERVER_POD" -- "$SPIRE_SERVER_BIN" bundle show -socketPath "$SPIRE_SOCKET" -format pem >"$SPIRE_BUNDLE_TMP" 2>/dev/null || true

if [[ ! -s "$SPIRE_BUNDLE_TMP" ]]; then
  echo "[verify_root_lifecycle] unable to read SPIRE bundle from spire-server" >&2
  exit 2
fi

kubectl -n "$SPIRE_NAMESPACE" logs "$SPIRE_SERVER_POD" -c spire-server --since="${SPIRE_LIFECYCLE_LOG_SINCE:-72h}" >"$SPIRE_LOGS_TMP" 2>/dev/null || true
python3 "$REPO_ROOT/scripts/trust/collect_spire_lifecycle_state.py" --logs-file "$SPIRE_LOGS_TMP" --out-json "$SPIRE_AUTHORITY_STATE_TMP"

bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
if [ ! -s "$TRUST_AUTHORITY_STATE_FILE" ]; then
  echo "[verify_root_lifecycle] trust authority state unavailable" >&2
  exit 2
fi

kubectl get secret spire-csr-ca -n istio-system -o jsonpath='{.data.ca\.crt}' | base64 -d >"$SPIRE_CSR_CA_TMP" \
  || {
    echo "[verify_root_lifecycle] unable to read spire-csr-ca issuance certificate" >&2
    exit 2
  }

python3 - "$SPIRE_AUTHORITY_STATE_TMP" "$TRUST_AUTHORITY_STATE_FILE" "$SPIRE_CSR_CA_TMP" <<'PY'
import json
import pathlib
import sys

spire_state_path = pathlib.Path(sys.argv[1])
trust_state_path = pathlib.Path(sys.argv[2])
csr_ca_path = pathlib.Path(sys.argv[3])

spire_state = json.loads(spire_state_path.read_text(encoding="utf-8"))
trust_state = json.loads(trust_state_path.read_text(encoding="utf-8"))
csr_ca_pem = csr_ca_path.read_text(encoding="utf-8").strip()

def x509_fields(pem: str) -> dict[str, str]:
    import subprocess
    import tempfile

    with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as fh:
        fh.write(pem if pem.endswith("\n") else pem + "\n")
        path = fh.name
    try:
        proc = subprocess.run(
            ["openssl", "x509", "-in", path, "-noout", "-serial", "-subject", "-issuer", "-startdate", "-enddate"],
            capture_output=True,
            text=True,
            check=False,
        )
    finally:
        pathlib.Path(path).unlink(missing_ok=True)
    if proc.returncode != 0:
        raise SystemExit(proc.stderr.strip() or proc.stdout.strip() or "unable to parse issuance certificate")
    fields: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        fields[key.strip()] = value.strip()
    return fields

csr_fields = x509_fields(csr_ca_pem)
active_root_pem = str(trust_state.get("active_root_pem") or "").strip()
active_root_serial = str(trust_state.get("active_root_serial") or "").strip().lower().lstrip("0") or "0"
active_root_fingerprint = str(trust_state.get("active_root_fingerprint") or "").strip().lower()
active_root_not_before = str(trust_state.get("active_root_not_before") or "").strip()
active_root_not_after = str(trust_state.get("active_root_not_after") or "").strip()

active = {
    "state": "ACTIVE",
    "serial": active_root_serial,
    "fingerprint_sha256": active_root_fingerprint,
    "pem": active_root_pem + ("\n" if active_root_pem and not active_root_pem.endswith("\n") else ""),
    "not_before": active_root_not_before or csr_fields.get("notBefore", ""),
    "not_after": active_root_not_after or csr_fields.get("notAfter", ""),
}
spire_state["source"] = "trust_authority_state+spire_ca_manager_logs"
spire_state["active"] = active
spire_state["active_authority_state"] = [active]
spire_state["active_authorities"] = [active]
spire_state_path.write_text(json.dumps(spire_state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

python3 "$REPO_ROOT/scripts/trust/trust_root_lifecycle_guard.py" \
  --bundle-file "$SPIRE_BUNDLE_TMP" \
  --spire-authority-state-file "$SPIRE_AUTHORITY_STATE_TMP" \
  --out-json "$REPO_ROOT/artifacts/trust/root_lifecycle_status.json" \
  --out-metrics "$REPO_ROOT/artifacts/trust/root_lifecycle_metrics.prom"

status_json="$REPO_ROOT/artifacts/trust/root_lifecycle_status.json"
if [[ ! -f "$status_json" ]]; then
  echo "[verify_root_lifecycle] missing status artifact" >&2
  exit 2
fi

state="$(jq -r '.state' "$status_json")"
valid_count="$(jq -r '.valid_root_count' "$status_json")"
future_count="$(jq -r '.future_root_count' "$status_json")"
coverage_gap="$(jq -r '.coverage_gap_detected // false' "$status_json")"
continuity_ok="$(jq -r '.continuity_ok // false' "$status_json")"
successor_count="$(jq -r '.successor_count // 0' "$status_json")"
spire_lifecycle_ok="$(jq -r '.spire_lifecycle_ok // false' "$status_json")"
continuous_successor_policy_ok="$(jq -r '.continuous_successor_policy_ok // false' "$status_json")"
prepare_due="$(jq -r '.prepare_due // false' "$status_json")"
continuity_state="$(jq -r '.continuity_state // "UNKNOWN"' "$status_json")"

echo "[verify_root_lifecycle] state=$state continuity_state=$continuity_state valid=$valid_count future=$future_count successor_count=$successor_count spire_lifecycle_ok=$spire_lifecycle_ok continuous_successor_policy_ok=$continuous_successor_policy_ok prepare_due=$prepare_due continuity_ok=$continuity_ok coverage_gap_detected=$coverage_gap" >&2

refresh_prepare_due_snapshot() {
  bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
  kubectl -n "$SPIRE_NAMESPACE" logs "$SPIRE_SERVER_POD" -c spire-server --since="${SPIRE_LIFECYCLE_LOG_SINCE:-72h}" >"$SPIRE_LOGS_TMP" 2>/dev/null || true
  python3 "$REPO_ROOT/scripts/trust/collect_spire_lifecycle_state.py" --logs-file "$SPIRE_LOGS_TMP" --out-json "$SPIRE_AUTHORITY_STATE_TMP"

  python3 "$REPO_ROOT/scripts/trust/trust_root_lifecycle_guard.py" \
    --bundle-file "$SPIRE_BUNDLE_TMP" \
    --spire-authority-state-file "$SPIRE_AUTHORITY_STATE_TMP" \
    --out-json "$REPO_ROOT/artifacts/trust/root_lifecycle_status.json" \
    --out-metrics "$REPO_ROOT/artifacts/trust/root_lifecycle_metrics.prom"
}

if [[ "$prepare_due" == "true" ]]; then
  refresh_success=false
  for attempt in 1 2 3; do
    if refresh_prepare_due_snapshot; then
      refresh_success=true
      break
    fi
    echo "[verify_root_lifecycle] prepare-due refresh attempt $attempt failed" >&2
  done
  if [[ "$refresh_success" != "true" ]]; then
    echo "[verify_root_lifecycle] unable to refresh SPIRE root lifecycle snapshot after prepare-due detection" >&2
    exit 2
  fi

  state="$(jq -r '.state' "$status_json")"
  valid_count="$(jq -r '.valid_root_count' "$status_json")"
  future_count="$(jq -r '.future_root_count' "$status_json")"
  coverage_gap="$(jq -r '.coverage_gap_detected // false' "$status_json")"
  continuity_ok="$(jq -r '.continuity_ok // false' "$status_json")"
  successor_count="$(jq -r '.successor_count // 0' "$status_json")"
  spire_lifecycle_ok="$(jq -r '.spire_lifecycle_ok // false' "$status_json")"
  continuous_successor_policy_ok="$(jq -r '.continuous_successor_policy_ok // false' "$status_json")"
  prepare_due="$(jq -r '.prepare_due // false' "$status_json")"
  continuity_state="$(jq -r '.continuity_state // "UNKNOWN"' "$status_json")"
fi

# Fail proof on exhausted or when the SPIRE lifecycle contract itself is violated.
if [[ "$state" == "exhausted" ]]; then
  echo "[FAIL] CONTRACT_VIOLATION: SPIRE bundle has no currently valid roots" >&2
  exit 2
fi

if [[ "$spire_lifecycle_ok" != "true" ]]; then
  echo "[FAIL] CONTRACT_VIOLATION: SPIRE lifecycle contract violated" >&2
  exit 2
fi

exit 0
