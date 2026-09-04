#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REGISTRY_ALIAS="${REGISTRY_ALIAS:-registry.threadforge.local}"
REGISTRY_PORT="${REGISTRY_PORT:-30500}"
SOURCE_CA="${SOURCE_CA:-${REPO_ROOT}/certs/threadforge-ingress-ca.crt}"
HOST_TRUST_DIR="/etc/docker/certs.d/${REGISTRY_ALIAS}:${REGISTRY_PORT}"
HOST_CA_PATH="${HOST_TRUST_DIR}/ca.crt"
ARTIFACT_DIR="${REPO_ROOT}/artifacts/host_trust"
ARTIFACT_PATH="${ARTIFACT_DIR}/host_trust_status.json"
MODE="verify"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    *)
      echo "[FAIL] HOST_TRUST_INVALID_ARG: unknown argument '$1'"
      exit 2
      ;;
  esac
done

if [[ "$MODE" != "verify" && "$MODE" != "prime" ]]; then
  echo "[FAIL] HOST_TRUST_INVALID_MODE: expected --mode verify|prime"
  exit 2
fi

mkdir -p "$ARTIFACT_DIR"

fail_missing_source() {
  write_artifact "HOST_TRUST_REQUIRED" "$MODE" "UNAVAILABLE" "MISSING" "false" "true" "true"
  echo "[FAIL] HOST_TRUST_REQUIRED: source CA is missing at ${SOURCE_CA}"
  echo "HOST_TRUST_REQUIRED"
  echo "HOST_TRUST_PATH=${HOST_CA_PATH}"
  echo "EXPECTED_CA_FINGERPRINT=UNAVAILABLE"
  echo "OBSERVED_CA_FINGERPRINT=MISSING"
  echo "SOURCE_CA_EXPIRED=true"
  echo "HOST_CA_EXPIRED=true"
  echo "OPERATOR_ACTION=make host-trust-prime"
  echo "HOST_TRUST_ARTIFACT=${ARTIFACT_PATH}"
  exit 2
}

emit_sudo_required_and_exit() {
  local purpose="$1"
  local stdin_tty="false"
  local stdout_tty="false"

  [[ -t 0 ]] && stdin_tty="true"
  [[ -t 1 ]] && stdout_tty="true"

  echo "[FAIL] SUDO_REQUIRED: ${purpose}"
  echo "TTY_STDIN_ATTACHED=${stdin_tty}"
  echo "TTY_STDOUT_ATTACHED=${stdout_tty}"
  echo "OPERATOR_ACTION=make host-trust-prime"
  exit 2
}

ensure_sudo_noninteractive_or_fail() {
  command -v sudo >/dev/null 2>&1 || emit_sudo_required_and_exit "host trust prime requires sudo"
  # NOPASSWD policies authorize commands, but sudo -v still requests credential validation.
  sudo -n true >/dev/null 2>&1 || emit_sudo_required_and_exit "host trust prime requires noninteractive sudo"
}

cert_fingerprint() {
  local cert_path="$1"
  openssl x509 -in "$cert_path" -noout -fingerprint -sha256 | sed 's/^sha256 Fingerprint=//'
}

cert_expired() {
  local cert_path="$1"
  if openssl x509 -in "$cert_path" -checkend 0 -noout >/dev/null 2>&1; then
    echo "false"
  else
    echo "true"
  fi
}

write_artifact() {
  local status="$1"
  local mode="$2"
  local expected_fp="$3"
  local observed_fp="$4"
  local observed_exists="$5"
  local source_expired="$6"
  local observed_expired="$7"

  python3 - "$ARTIFACT_PATH" "$status" "$mode" "$SOURCE_CA" "$HOST_CA_PATH" "$expected_fp" "$observed_fp" "$observed_exists" "$source_expired" "$observed_expired" <<'PY'
import json
import sys
from datetime import datetime, timezone

(
    artifact,
    status,
    mode,
    source_ca,
    host_ca,
    expected_fp,
    observed_fp,
    observed_exists,
    source_expired,
    observed_expired,
) = sys.argv[1:]

payload = {
    "status": status,
    "mode": mode,
    "source_ca": source_ca,
    "host_ca": host_ca,
    "expected_fingerprint": expected_fp,
    "observed_fingerprint": observed_fp,
    "observed_exists": observed_exists == "true",
    "source_expired": source_expired == "true",
    "observed_expired": observed_expired == "true",
    "timestamp_utc": datetime.now(timezone.utc).isoformat(),
}

with open(artifact, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
PY
}

emit_host_trust_required() {
  local reason="$1"
  local expected_fp="$2"
  local observed_fp="$3"
  local observed_exists="$4"
  local source_expired="$5"
  local observed_expired="$6"

  write_artifact "HOST_TRUST_REQUIRED" "$MODE" "$expected_fp" "$observed_fp" "$observed_exists" "$source_expired" "$observed_expired"

  echo "[FAIL] HOST_TRUST_REQUIRED: ${reason}"
  echo "HOST_TRUST_REQUIRED"
  echo "HOST_TRUST_PATH=${HOST_CA_PATH}"
  echo "EXPECTED_CA_FINGERPRINT=${expected_fp}"
  echo "OBSERVED_CA_FINGERPRINT=${observed_fp}"
  echo "SOURCE_CA_EXPIRED=${source_expired}"
  echo "HOST_CA_EXPIRED=${observed_expired}"
  echo "OPERATOR_ACTION=make host-trust-prime"
  echo "HOST_TRUST_ARTIFACT=${ARTIFACT_PATH}"
  exit 2
}

[[ -f "$SOURCE_CA" ]] || fail_missing_source

expected_fp="$(cert_fingerprint "$SOURCE_CA")"
source_expired="$(cert_expired "$SOURCE_CA")"

observed_exists="false"
observed_fp="MISSING"
observed_expired="true"

if [[ -f "$HOST_CA_PATH" ]]; then
  observed_exists="true"
  observed_fp="$(cert_fingerprint "$HOST_CA_PATH")"
  observed_expired="$(cert_expired "$HOST_CA_PATH")"
fi

if [[ "$MODE" == "prime" ]]; then
  ensure_sudo_noninteractive_or_fail
  sudo mkdir -p "$HOST_TRUST_DIR"
  sudo cp "$SOURCE_CA" "$HOST_CA_PATH"
  observed_exists="true"
  observed_fp="$(cert_fingerprint "$HOST_CA_PATH")"
  observed_expired="$(cert_expired "$HOST_CA_PATH")"
fi

if [[ "$source_expired" == "true" ]]; then
  emit_host_trust_required "source CA is expired" "$expected_fp" "$observed_fp" "$observed_exists" "$source_expired" "$observed_expired"
fi

if [[ "$observed_exists" != "true" ]]; then
  emit_host_trust_required "host Docker trust CA is missing" "$expected_fp" "$observed_fp" "$observed_exists" "$source_expired" "$observed_expired"
fi

if [[ "$observed_expired" == "true" ]]; then
  emit_host_trust_required "host Docker trust CA is expired" "$expected_fp" "$observed_fp" "$observed_exists" "$source_expired" "$observed_expired"
fi

if [[ "$observed_fp" != "$expected_fp" ]]; then
  emit_host_trust_required "host Docker trust CA fingerprint mismatch" "$expected_fp" "$observed_fp" "$observed_exists" "$source_expired" "$observed_expired"
fi

write_artifact "PASS" "$MODE" "$expected_fp" "$observed_fp" "$observed_exists" "$source_expired" "$observed_expired"
echo "[PASS] HOST_TRUST_VERIFIED"
echo "HOST_TRUST_PATH=${HOST_CA_PATH}"
echo "HOST_TRUST_ARTIFACT=${ARTIFACT_PATH}"
echo "HOST_TRUST_FINGERPRINT=${observed_fp}"
