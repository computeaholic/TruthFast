#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

# Rotation correctness must be proven independently at single replica.
# A second two-replica run is allowed only as proof-noise smoothing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_PATH="$REPO_ROOT/artifacts/cert_rotation_validation.json"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

ROTATION_NAMESPACE="${ROTATION_NAMESPACE:-threadforge-test}"
ROTATION_APP_LABEL="${ROTATION_APP_LABEL:-echo}"
ROTATION_TRAFFIC_DURATION_SECONDS="${ROTATION_TRAFFIC_DURATION_SECONDS:-240}"
ROTATION_TRAFFIC_INTERVAL_SECONDS="${ROTATION_TRAFFIC_INTERVAL_SECONDS:-0.5}"
ROTATION_TARGET_PATH="${ROTATION_TARGET_PATH:-/healthz}"
ROTATION_ROLLOUT_TIMEOUT_SECONDS="${ROTATION_ROLLOUT_TIMEOUT_SECONDS:-90}"
ROTATION_SMOOTHING_ENABLED="${ROTATION_SMOOTHING_ENABLED:-false}"
ROTATION_MAX_TRIGGER_TTL_SECONDS="${ROTATION_MAX_TRIGGER_TTL_SECONDS:-210}"
# shellcheck source=scripts/lib/identity_contract.sh
source "$REPO_ROOT/scripts/lib/identity_contract.sh"
require_trust_domain
TRUST_DOMAIN="${ROTATION_TRUST_DOMAIN:-${SPIFFE_TRUST_DOMAIN}}"

TMP_DIR=""
TARGET_URL=""
ORIGINAL_REPLICAS=""
AUTH_RESULT_PATH=""
SMOOTH_RESULT_PATH=""

resolve_rotation_base_url() {
  if [ -n "${THREADFORGE_INGRESS_URL:-}" ]; then
    printf '%s\n' "${THREADFORGE_INGRESS_URL%/}"
    return 0
  fi

  local node_ip node_port
  node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  node_port="$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || true)"

  if [ -z "$node_ip" ] || [ -z "$node_port" ]; then
    return 1
  fi

  printf 'http://%s:%s\n' "$node_ip" "$node_port"
}

fail() {
  echo "[FAIL] CONTRACT_VIOLATION: $1"
  exit 2
}

cleanup() {
  if [ -n "$ORIGINAL_REPLICAS" ]; then
    kubectl -n "$ROTATION_NAMESPACE" scale deploy "$ROTATION_APP_LABEL" --replicas="$ORIGINAL_REPLICAS" >/dev/null 2>&1 || true
    wait_for_ready_sidecar_pod "$ROTATION_NAMESPACE" "$ROTATION_APP_LABEL" "" 120 >/dev/null 2>&1 || true
  fi
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

ensure_cluster_readable || exit $?
fail_if_proof_mutation_blocked "verify_cert_rotation_continuity.sh" "scale exec"

get_ready_sidecar_pod() {
  local ns="$1"
  local app="$2"

  kubectl get pods -n "$ns" -l "app=$app" --request-timeout=5s -o json 2>/dev/null | python3 -c 'import json,sys
try:
  doc=json.load(sys.stdin)
except Exception:
  print("")
  raise SystemExit(0)
for pod in doc.get("items", []):
  if pod.get("status", {}).get("phase") != "Running":
    continue
  conds = pod.get("status", {}).get("conditions") or []
  ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in conds if isinstance(c, dict))
  if not ready:
    continue
  containers = [c.get("name") for c in (pod.get("spec", {}).get("containers") or []) if isinstance(c, dict)]
  if "istio-proxy" not in containers:
    continue
  print(pod.get("metadata", {}).get("name", ""))
  raise SystemExit(0)
print("")'
}

wait_for_ready_sidecar_pod() {
  local ns="$1"
  local app="$2"
  local exclude_pod="$3"
  local timeout_seconds="$4"
  local deadline pod_name

  deadline=$((SECONDS + timeout_seconds))
  while [ "$SECONDS" -lt "$deadline" ]; do
    pod_name="$(get_ready_sidecar_pod "$ns" "$app")"
    if [ -n "$pod_name" ] && [ "$pod_name" != "$exclude_pod" ]; then
      printf '%s\n' "$pod_name"
      return 0
    fi
    sleep 2
  done

  return 1
}

get_workload_service_account() {
  local ns="$1"
  local pod="$2"

  kubectl get pod -n "$ns" "$pod" -o jsonpath='{.spec.serviceAccountName}' 2>/dev/null || true
}

get_envoy_leaf_details() {
  local ns="$1"
  local pod="$2"
  local expected_uri="$3"
  local certs_json=""

  certs_json="$(timeout --foreground 10s kubectl exec -n "$ns" "$pod" -c istio-proxy -- curl -sf --max-time 5 http://127.0.0.1:15000/certs 2>/dev/null || true)"
  if [ -z "$certs_json" ]; then
    return 1
  fi

  python3 - "$certs_json" "$expected_uri" <<'PY'
import json
import sys


def norm(value: str) -> str:
    value = (value or "").strip().lower()
    if value.startswith("0x"):
        value = value[2:]
    value = value.lstrip("0")
    return value or "0"


try:
    doc = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)

expected_uri = sys.argv[2]
certs = doc.get("certificates") if isinstance(doc, dict) else None
if not isinstance(certs, list):
    raise SystemExit(1)

for cert in certs:
    if not isinstance(cert, dict):
        continue
    chain = cert.get("cert_chain") or []
    if not isinstance(chain, list):
        continue
    for entry in chain:
        if not isinstance(entry, dict):
            continue
        sans = entry.get("subject_alt_names") or []
        san_uris = [
            san.get("uri")
            for san in sans
            if isinstance(san, dict) and isinstance(san.get("uri"), str)
        ]
        if expected_uri not in san_uris:
            continue
        serial = entry.get("serial_number")
        valid_from = entry.get("valid_from")
        expiration_time = entry.get("expiration_time")
        ca_serials = []
        for ca in cert.get("ca_cert") or []:
            if not isinstance(ca, dict):
                continue
            ca_serial = ca.get("serial_number")
            if isinstance(ca_serial, str) and ca_serial.strip():
                ca_serials.append(norm(ca_serial))
        root_fingerprint = ",".join(sorted(set(ca_serials)))
        if isinstance(serial, str) and serial.strip() and isinstance(valid_from, str) and isinstance(expiration_time, str):
            print(f"{norm(serial)}\t{valid_from}\t{expiration_time}\t{root_fingerprint}")
            raise SystemExit(0)

raise SystemExit(1)
PY
}

ttl_remaining_seconds() {
  local expiration_value="$1"

  python3 - "$expiration_value" <<'PY'
import datetime as dt
import sys

value = (sys.argv[1] or "").strip()
if not value:
  raise SystemExit(1)

try:
  try:
    exp_dt = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
  except ValueError:
    exp_dt = dt.datetime.strptime(value, "%b %d %H:%M:%S %Y GMT").replace(tzinfo=dt.timezone.utc)
  now_dt = dt.datetime.now(dt.timezone.utc)
  print(int((exp_dt - now_dt).total_seconds()))
except Exception:
  raise SystemExit(1)
PY
}

run_rotation_test() {
  local replicas="$1"
  local authoritative="$2"
  local result_path="$3"

  local tmp_dir traffic_log failures_log err_file
  local pod_before pod_after workload_sa expected_uri current_pod current_cert
  local cert_before cert_after
  local serial_before serial_after valid_from_before valid_from_after expiration_before expiration_after
  local root_before root_after
  local rotation_observed status
  local end_at observe_deadline initial_ttl_remaining last_observe_at
  local ts code rc err

  tmp_dir="$(mktemp -d)"
  traffic_log="$tmp_dir/traffic.jsonl"
  failures_log="$tmp_dir/failures.log"
  err_file="$tmp_dir/curl.err"
  touch "$failures_log"

  if ! kubectl -n "$ROTATION_NAMESPACE" scale deploy "$ROTATION_APP_LABEL" --replicas="$replicas" >/dev/null 2>&1; then
    echo "failed to scale deployment/$ROTATION_APP_LABEL to $replicas replicas" >> "$failures_log"
  elif ! wait_for_ready_sidecar_pod "$ROTATION_NAMESPACE" "$ROTATION_APP_LABEL" "" "$ROTATION_ROLLOUT_TIMEOUT_SECONDS" >/dev/null 2>&1; then
    echo "deployment/$ROTATION_APP_LABEL not ready at replicas=$replicas" >> "$failures_log"
  fi

  pod_before="$(get_ready_sidecar_pod "$ROTATION_NAMESPACE" "$ROTATION_APP_LABEL")"
  if [ -z "$pod_before" ]; then
    echo "no ready sidecar pod before restart (replicas=$replicas)" >> "$failures_log"
  fi

  expected_uri=""
  serial_before=""
  valid_from_before=""
  expiration_before=""
  serial_after=""
  valid_from_after=""
  expiration_after=""
  root_before=""
  root_after=""
  cert_observed_at=""

  if [ -n "$pod_before" ]; then
    workload_sa="$(get_workload_service_account "$ROTATION_NAMESPACE" "$pod_before")"
    if [ -z "$workload_sa" ]; then
      echo "unable to determine service account for pod $pod_before" >> "$failures_log"
    else
      expected_uri="spiffe://$TRUST_DOMAIN/ns/${ROTATION_NAMESPACE}/sa/${workload_sa}"
      cert_before="$(get_envoy_leaf_details "$ROTATION_NAMESPACE" "$pod_before" "$expected_uri" || true)"
      if [ -z "$cert_before" ]; then
        echo "unable to read Envoy leaf cert details before restart" >> "$failures_log"
      else
        IFS=$'\t' read -r serial_before valid_from_before expiration_before root_before <<< "$cert_before"
        initial_ttl_remaining="$(ttl_remaining_seconds "$expiration_before" 2>/dev/null || true)"
        if ! [[ "$initial_ttl_remaining" =~ ^-?[0-9]+$ ]]; then
          echo "unable to determine initial cert TTL from expiration value $expiration_before" >> "$failures_log"
        elif [ "$initial_ttl_remaining" -gt "$ROTATION_MAX_TRIGGER_TTL_SECONDS" ]; then
          echo "initial cert TTL ${initial_ttl_remaining}s exceeds live rotation trigger window ${ROTATION_MAX_TRIGGER_TTL_SECONDS}s" >> "$failures_log"
        fi
      fi
    fi
  fi

  end_at=$(( $(date +%s) + ROTATION_TRAFFIC_DURATION_SECONDS ))
  observe_deadline="$end_at"
  last_observe_at=0
  while [ "$(date +%s)" -lt "$observe_deadline" ]; do
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    code="000"
    rc=0
    err=""

    if code="$(curl --silent --show-error --fail --max-time 5 --output /dev/null --write-out "%{http_code}" "$TARGET_URL" 2>"$err_file")"; then
      rc=0
    else
      rc=$?
    fi

    if [ -f "$err_file" ]; then
      err="$(tr '\n' ' ' < "$err_file" | tr '"' "'" | sed 's/[[:space:]]\+/ /g')"
    fi
    printf '{"ts":"%s","http_code":"%s","curl_rc":%s,"error":"%s"}\n' "$ts" "$code" "$rc" "$err" >> "$traffic_log"

    if [ $(( $(date +%s) - last_observe_at )) -lt 2 ]; then
      sleep "$ROTATION_TRAFFIC_INTERVAL_SECONDS"
      continue
    fi

    last_observe_at="$(date +%s)"
    current_pod="$(get_ready_sidecar_pod "$ROTATION_NAMESPACE" "$ROTATION_APP_LABEL")"
    if [ -z "$current_pod" ]; then
      sleep "$ROTATION_TRAFFIC_INTERVAL_SECONDS"
      continue
    fi
    if [ "$current_pod" != "$pod_before" ]; then
      # Pod replacement can occur during rollout noise; rebind observation to the
      # new ready pod and continue the same live cert-rotation window.
      pod_before="$current_pod"
      if [ -n "$expected_uri" ]; then
        current_cert="$(get_envoy_leaf_details "$ROTATION_NAMESPACE" "$current_pod" "$expected_uri" || true)"
        if [ -n "$current_cert" ]; then
          IFS=$'\t' read -r serial_before valid_from_before expiration_before root_before <<< "$current_cert"
          serial_after=""
          valid_from_after=""
          expiration_after=""
          root_after=""
        fi
      fi
      sleep "$ROTATION_TRAFFIC_INTERVAL_SECONDS"
      continue
    fi
    if [ -n "$expected_uri" ]; then
      current_cert="$(get_envoy_leaf_details "$ROTATION_NAMESPACE" "$current_pod" "$expected_uri" || true)"
      if [ -n "$current_cert" ]; then
        IFS=$'\t' read -r serial_after valid_from_after expiration_after root_after <<< "$current_cert"
        if [ -n "$serial_before" ] && { [ "$serial_before" != "$serial_after" ] || [ "$valid_from_before" != "$valid_from_after" ] || [ "$expiration_before" != "$expiration_after" ]; }; then
          cert_observed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          pod_after="$current_pod"
          break
        fi
      fi
    fi

    sleep "$ROTATION_TRAFFIC_INTERVAL_SECONDS"
  done

  if [ -z "${pod_after:-}" ]; then
    pod_after="$(get_ready_sidecar_pod "$ROTATION_NAMESPACE" "$ROTATION_APP_LABEL")"
  fi
  if [ -z "$pod_after" ]; then
    echo "no ready sidecar pod after live rotation observation (replicas=$replicas)" >> "$failures_log"
  elif [ -n "$expected_uri" ] && [ -z "$serial_after" ]; then
    cert_after="$(get_envoy_leaf_details "$ROTATION_NAMESPACE" "$pod_after" "$expected_uri" || true)"
    if [ -z "$cert_after" ]; then
      echo "unable to read Envoy leaf cert details after live rotation observation" >> "$failures_log"
    else
      IFS=$'\t' read -r serial_after valid_from_after expiration_after root_after <<< "$cert_after"
      cert_observed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi
  fi

  rotation_observed="false"
  if [ -n "$serial_before" ] && [ -n "$serial_after" ] && {
    [ "$serial_before" != "$serial_after" ] || [ "$valid_from_before" != "$valid_from_after" ] || [ "$expiration_before" != "$expiration_after" ];
  }; then
    rotation_observed="true"
  fi
  if [ "$rotation_observed" != "true" ]; then
    echo "workload cert details did not change during live rotation observation window (replicas=$replicas)" >> "$failures_log"
  fi

  python3 - "$traffic_log" "$failures_log" "$replicas" "$authoritative" "$expected_uri" "$serial_before" "$serial_after" "$valid_from_before" "$valid_from_after" "$expiration_before" "$expiration_after" "$root_before" "$root_after" "$result_path" "$ROTATION_MAX_TRIGGER_TTL_SECONDS" "$cert_observed_at" <<'PY'
import datetime
import json
import pathlib
import re
import sys

(
  traffic_log_path,
  failures_path,
  replicas,
  authoritative,
  expected_uri,
  serial_before,
  serial_after,
  valid_from_before,
  valid_from_after,
  expiration_before,
  expiration_after,
  root_before,
  root_after,
  result_path,
  rotation_max_ttl_seconds,
  cert_observed_at,
) = sys.argv[1:]

rows = []
path = pathlib.Path(traffic_log_path)
if path.exists():
    for line in path.read_text().splitlines():
      line = line.strip()
      if not line:
        continue
      try:
        rows.append(json.loads(line))
      except Exception:
        continue

handshake_re = re.compile(r"(tls|ssl|x509|handshake|certificate)", re.IGNORECASE)
summary = {
  "total_requests": 0,
  "http_2xx": 0,
  "http_3xx": 0,
  "http_4xx": 0,
  "http_5xx": 0,
  "http_503": 0,
  "curl_failures": 0,
  "handshake_failures": 0,
}

for row in rows:
    summary["total_requests"] += 1
    rc = int(row.get("curl_rc", 1))
    code_raw = str(row.get("http_code", "000"))
    err = str(row.get("error", ""))

    if rc != 0:
      summary["curl_failures"] += 1
      if handshake_re.search(err):
        summary["handshake_failures"] += 1

    if code_raw.isdigit():
      code = int(code_raw)
      if 200 <= code < 300:
        summary["http_2xx"] += 1
      elif 300 <= code < 400:
        summary["http_3xx"] += 1
      elif 400 <= code < 500:
        summary["http_4xx"] += 1
      elif 500 <= code < 600:
        summary["http_5xx"] += 1
        if code == 503:
          summary["http_503"] += 1

failures = [
  line.strip()
  for line in pathlib.Path(failures_path).read_text().splitlines()
  if line.strip()
]

if summary["http_503"] > 0:
  failures.append(f"observed {summary['http_503']} HTTP 503 responses during cert rotation window")
if summary["handshake_failures"] > 0:
  failures.append(f"observed {summary['handshake_failures']} TLS/handshake failures during cert rotation window")

# cert_not_after - now < ROTATION_MAX_TTL_SECONDS: proves cert was recently issued (not stale)
ROTATION_MAX_TTL_SECONDS = int(rotation_max_ttl_seconds)
cert_ttl_remaining_seconds = None
cert_ttl_valid = False
if expiration_after:
    try:
        exp_str = expiration_after.strip()
        try:
            exp_dt = datetime.datetime.fromisoformat(exp_str.replace("Z", "+00:00"))
        except ValueError:
            # Fallback: ASN.1 / Envoy legacy format e.g. "Jan 15 10:30:00 2024 GMT"
            exp_dt = datetime.datetime.strptime(
                exp_str, "%b %d %H:%M:%S %Y GMT"
            ).replace(tzinfo=datetime.timezone.utc)
        observed_dt = None
        if cert_observed_at:
          observed_dt = datetime.datetime.fromisoformat(cert_observed_at.replace("Z", "+00:00"))
        if observed_dt is None:
          observed_dt = datetime.datetime.now(datetime.timezone.utc)
        cert_ttl_remaining_seconds = int((exp_dt - observed_dt).total_seconds())
        cert_ttl_valid = 0 < cert_ttl_remaining_seconds < ROTATION_MAX_TTL_SECONDS
    except Exception:
        cert_ttl_valid = False
if not cert_ttl_valid:
    failures.append(
        (
            f"cert TTL remaining {cert_ttl_remaining_seconds}s exceeds rotation threshold "
            f"{ROTATION_MAX_TTL_SECONDS}s (cert_not_after - now must be < threshold)"
        )
        if cert_ttl_remaining_seconds is not None
        else "cert expiration_after unparseable or absent — cannot verify cert freshness"
    )

# verify_new_serial_seen_post_rotation: serial must change and new value confirmed present
cert_reload_verified = bool(
    serial_before and serial_after and serial_before != serial_after
)
if not cert_reload_verified and authoritative.lower() == "true":
    failures.append(
        f"cert_reload_verified=false: Envoy serial unchanged ({serial_before!r}) after "
    "live observation window — workload did not receive a new SPIRE-issued cert in place"
    )

trust_root_stable = bool(root_before and root_after and root_before == root_after)
if authoritative.lower() == "true" and not trust_root_stable:
  failures.append(
    "trust_root_stable=false: Envoy CA chain fingerprint changed across rotation window"
  )

status = "PASS" if not failures else "FAIL"

result = {
  "status": status,
  "authoritative": authoritative.lower() == "true",
  "replicas": int(replicas),
  "workload_uri": expected_uri,
  "rotation": {
    "serial_before": serial_before,
    "serial_after": serial_after,
    "valid_from_before": valid_from_before,
    "valid_from_after": valid_from_after,
    "expiration_before": expiration_before,
    "expiration_after": expiration_after,
    "root_before": root_before,
    "root_after": root_after,
    "observed": bool(serial_before and serial_after and (
      serial_before != serial_after or
      valid_from_before != valid_from_after or
      expiration_before != expiration_after
    )),
    "cert_reload_verified": cert_reload_verified,
    "trust_root_stable": trust_root_stable,
    "cert_ttl_remaining_seconds": cert_ttl_remaining_seconds,
    "cert_ttl_valid": cert_ttl_valid,
    "rotation_max_ttl_seconds": ROTATION_MAX_TTL_SECONDS,
  },
  "traffic_summary": summary,
  "failures": failures,
}

pathlib.Path(result_path).write_text(json.dumps(result, indent=2) + "\n")
PY

rm -rf "$tmp_dir"

if [ "$authoritative" = "true" ]; then
    python3 - "$result_path" <<'PY'
import json, sys
doc = json.loads(open(sys.argv[1], 'r', encoding='utf-8').read())
raise SystemExit(0 if doc.get("status") == "PASS" else 1)
PY
    return $?
  fi

  return 0
}

write_combined_artifact() {
  local auth_result="$1"
  local smooth_result="$2"

  python3 - "$auth_result" "$smooth_result" "$ARTIFACT_PATH" "$ROTATION_TRAFFIC_DURATION_SECONDS" "$ROTATION_TRAFFIC_INTERVAL_SECONDS" "$TARGET_URL" <<'PY'
import json
import pathlib
import sys

auth_path, smooth_path, artifact_path, duration, interval, target_url = sys.argv[1:]

auth = json.loads(pathlib.Path(auth_path).read_text())
smooth = json.loads(pathlib.Path(smooth_path).read_text()) if pathlib.Path(smooth_path).exists() else None

artifact = {
  "status": "PASS" if auth.get("status") == "PASS" else "FAIL",
  "contract": {
    "single_replica_authoritative": True,
    "optional_smoothing_executed": bool(smooth),
    "required": [
      "single_replica_rotation_observed",
      "single_replica_no_http_503",
      "single_replica_no_tls_or_handshake_failure",
      "system_recovery_after_rotation",
    ],
  },
  "config": {
    "traffic_duration_seconds": int(duration),
    "traffic_interval_seconds": float(interval),
    "target_url": target_url,
  },
  "authoritative_single_replica": auth,
  "optional_noise_smoothing": smooth,
}

pathlib.Path(artifact_path).write_text(json.dumps(artifact, indent=2) + "\n")
PY
}

mkdir -p "$(dirname "$ARTIFACT_PATH")"
TMP_DIR="$(mktemp -d)"
AUTH_RESULT_PATH="$TMP_DIR/authoritative.json"
SMOOTH_RESULT_PATH="$TMP_DIR/smoothing.json"

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "[FAIL] cluster unreachable"
  exit 10
fi

TARGET_BASE_URL="$(resolve_rotation_base_url || true)"
if [ -z "$TARGET_BASE_URL" ]; then
  fail "unable to determine ingress URL for cert rotation continuity checks"
fi

TARGET_URL="${TARGET_BASE_URL%/}${ROTATION_TARGET_PATH}"
ORIGINAL_REPLICAS="$(kubectl -n "$ROTATION_NAMESPACE" get deploy "$ROTATION_APP_LABEL" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
if ! [[ "$ORIGINAL_REPLICAS" =~ ^[0-9]+$ ]]; then
  fail "unable to read current replica count for deployment/$ROTATION_APP_LABEL"
fi

echo "[rotation] authoritative correctness check: run_rotation_test --replicas=1"
if ! run_rotation_test 1 true "$AUTH_RESULT_PATH"; then
  write_combined_artifact "$AUTH_RESULT_PATH" "$SMOOTH_RESULT_PATH"
  echo "[FAIL] ROTATION CORRECTNESS FAILURE"
  exit 2
fi

if [ "$ROTATION_SMOOTHING_ENABLED" = "true" ]; then
  echo "[rotation] secondary validation run: run_rotation_test --replicas=2"
  if ! run_rotation_test 2 false "$SMOOTH_RESULT_PATH"; then
    :
  fi
fi

write_combined_artifact "$AUTH_RESULT_PATH" "$SMOOTH_RESULT_PATH"

echo "[PASS] Live SDS cert rotation integrity independently verified at single-replica."

exit 0
