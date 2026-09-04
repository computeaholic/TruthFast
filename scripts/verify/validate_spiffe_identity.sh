#!/usr/bin/env bash
set -euo pipefail

capture_output() {
  local __var_name="$1"
  shift
  local output=""
  output="$("$@")"
  local rc=$?
  printf -v "$__var_name" '%s' "$output"
  return "$rc"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MATRIX_PATH="$REPO_ROOT/artifacts/service_trust_matrix.json"
OUT_PATH="$REPO_ROOT/artifacts/spiffe_validation.json"
FAILURE_OUT_PATH="$REPO_ROOT/artifacts/debug/echo_identity_failure.log"
SPIRE_NS="spire-system"
SPIRE_SERVER_POD=""
KUBECTL_BIN="$(type -P kubectl 2>/dev/null || true)"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

run_kubectl() {
  "$KUBECTL_BIN" "$@"
}

if ! python3 "$REPO_ROOT/scripts/identity/generate_trust_matrix.py" >/dev/null 2>&1; then
  echo "[FAIL] unable to refresh service trust matrix from live cluster state"
  exit 2
fi

SPIRE_SERVER_POD="$(select_active_spire_server_pod "$SPIRE_NS" || true)"
if [ -z "$SPIRE_SERVER_POD" ]; then
  echo "[FAIL] unable to select a ready spire-server pod"
  exit 2
fi
SERVER_SOCKET="/run/spire/private/spire-server.sock"

run_spire_server() {
  run_kubectl exec -n "$SPIRE_NS" -c spire-server "$SPIRE_SERVER_POD" -- /opt/spire/bin/spire-server -socketPath "$SERVER_SOCKET" "$@"
}

if [ ! -f "$MATRIX_PATH" ]; then
  echo "[FAIL] missing: artifacts/service_trust_matrix.json"
  exit 2
fi

if [ -z "$KUBECTL_BIN" ] || [ ! -x "$KUBECTL_BIN" ]; then
  echo "[FAIL] kubectl binary not found"
  exit 2
fi

extract_spiffe_from_cert_dump() {
  local expected="$1"
  local cert_dump="$2"
  python3 - "$expected" "$cert_dump" <<'PY'
import json
import sys

expected = sys.argv[1]
raw = sys.argv[2].strip()
if not raw:
    sys.exit(0)

try:
    payload = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)

uris = []
for cert in payload.get("certificates", []):
    for chain in cert.get("cert_chain", []):
        for san in chain.get("subject_alt_names", []):
            uri = san.get("uri")
            if isinstance(uri, str) and uri:
                uris.append(uri)

if expected in uris:
    print(expected)
elif uris:
    print(uris[0])
PY
}

dump_echo_failure_debug() {
  local namespace="$1"
  local pod="$2"
  local service_account="$3"
  local expected_spiffe="$4"
  local observed_spiffe="$5"
  local cert_dump="$6"
  local spire_entries="$7"
  local sidecar_containers=""

  mkdir -p "$(dirname "$FAILURE_OUT_PATH")"
  capture_output sidecar_containers run_kubectl get pod "$pod" -n "$namespace" -o jsonpath='{range .spec.containers[*]}{.name}{","}{end}'

  {
    echo "[debug] expected_spiffe=$expected_spiffe"
    echo "[debug] observed_spiffe=$observed_spiffe"
    echo "[debug] pod=$namespace/$pod"
    echo "[debug] service_account=$service_account"
    echo "[debug] sidecar_containers=$sidecar_containers"
    echo
    echo "=== pod spec ==="
    run_kubectl get pod "$pod" -n "$namespace" -o yaml || true
    echo
    echo "=== cert dump ==="
    if [ -n "$cert_dump" ]; then
      printf '%s\n' "$cert_dump"
    else
      run_kubectl exec -n "$namespace" "$pod" -c istio-proxy -- curl -s localhost:15000/certs || true
    fi
    echo
    echo "=== relevant SPIRE entries ==="
    if [ -n "$spire_entries" ]; then
      printf '%s\n' "$spire_entries"
    else
      run_spire_server entry show -selector "k8s:ns:$namespace" -selector "k8s:sa:$service_account" 2>/dev/null || true
    fi
  } > "$FAILURE_OUT_PATH"
}

tmp_services="$(mktemp)"
tmp_results="$(mktemp)"
cleanup_tmp() {
  rm -f "$tmp_services" "$tmp_results"
}
trap cleanup_tmp EXIT

python3 - "$MATRIX_PATH" > "$tmp_services" <<'PY'
import json
import pathlib
import sys

matrix = json.loads(pathlib.Path(sys.argv[1]).read_text())
services = matrix.get("services", [])
if not isinstance(services, list):
    sys.exit(2)

for svc in services:
    if not isinstance(svc, dict):
        continue
    name = svc.get("name")
    namespace = svc.get("namespace")
    service_account = svc.get("service_account")
    spiffe_id = svc.get("spiffe_id")
    if not all(isinstance(v, str) and v for v in [name, namespace, service_account, spiffe_id]):
        print(f"INVALID\t{name or ''}\t{namespace or ''}\t{service_account or ''}\t{spiffe_id or ''}")
        continue
    print(f"OK\t{name}\t{namespace}\t{service_account}\t{spiffe_id}")
PY
rc_services=$?
if [ "$rc_services" -ne 0 ]; then
  if [ "$rc_services" -eq 10 ]; then
    exit 10
  fi
  exit 2
fi

while IFS=$'\t' read -r status name namespace service_account expected_spiffe; do
  if [ "$status" != "OK" ]; then
    printf '%s\t%s\t%s\t%s\n' "$name" "$expected_spiffe" "" "FAIL" >> "$tmp_results"
    continue
  fi

  pod=""
  capture_output pod run_kubectl get pods -n "$namespace" -l "app=$name" -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}'
  rc_pod=$?
  if [ "$rc_pod" -ne 0 ]; then
    pod=""
  else
    pod="$(printf '%s\n' "$pod" | sed -n '1p')"
  fi

  if [ -z "$pod" ]; then
    echo "[FAIL] service pod missing: $namespace/$name"
    printf '%s\t%s\t%s\t%s\n' "$name" "$expected_spiffe" "" "FAIL" >> "$tmp_results"
    continue
  fi

  observed_spiffe=""
  cert_found="0"
  cert_dump=""
  capture_output cert_dump run_kubectl exec -n "$namespace" "$pod" -c istio-proxy -- curl -fsS localhost:15000/certs
  rc_cert_dump=$?
  if [ "$rc_cert_dump" -eq 0 ] && [ -n "$cert_dump" ]; then
    observed_spiffe="$(extract_spiffe_from_cert_dump "$expected_spiffe" "$cert_dump")"
    if [ -n "$observed_spiffe" ]; then
      cert_found="1"
    fi
  fi

  if [ -z "$observed_spiffe" ]; then
    if [ "$name" = "echo" ] && [ "$namespace" = "threadforge-test" ]; then
      dump_echo_failure_debug "$namespace" "$pod" "$service_account" "$expected_spiffe" "$observed_spiffe" "$cert_dump" ""
    fi
    echo "[FAIL] no SPIFFE ID or certificate block returned for pod $namespace/$pod"
    printf '%s\t%s\t%s\t%s\n' "$name" "$expected_spiffe" "$observed_spiffe" "FAIL" >> "$tmp_results"
    continue
  fi
  if [ "$cert_found" != "1" ]; then
    if [ "$name" = "echo" ] && [ "$namespace" = "threadforge-test" ]; then
      dump_echo_failure_debug "$namespace" "$pod" "$service_account" "$expected_spiffe" "$observed_spiffe" "$cert_dump" ""
    fi
    echo "[FAIL] no SPIFFE ID or certificate block returned for pod $namespace/$pod"
    printf '%s\t%s\t%s\t%s\n' "$name" "$expected_spiffe" "$observed_spiffe" "FAIL" >> "$tmp_results"
    continue
  fi

  if [ "$observed_spiffe" = "$expected_spiffe" ]; then
    printf '%s\t%s\t%s\t%s\n' "$name" "$expected_spiffe" "$observed_spiffe" "PASS" >> "$tmp_results"
  else
    if [ "$name" = "echo" ] && [ "$namespace" = "threadforge-test" ]; then
      dump_echo_failure_debug "$namespace" "$pod" "$service_account" "$expected_spiffe" "$observed_spiffe" "$cert_dump" ""
    fi
    echo "[FAIL] SPIFFE mismatch for $namespace/$name expected=$expected_spiffe observed=$observed_spiffe"
    printf '%s\t%s\t%s\t%s\n' "$name" "$expected_spiffe" "$observed_spiffe" "FAIL" >> "$tmp_results"
  fi
done < "$tmp_services"

python3 - "$tmp_results" "$OUT_PATH" "$MATRIX_PATH" <<'PY'
import json
import pathlib
import sys

rows_path = pathlib.Path(sys.argv[1])
out_path = pathlib.Path(sys.argv[2])
matrix_path = pathlib.Path(sys.argv[3])

services = []
failures = 0
for line in rows_path.read_text().splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    if len(parts) != 4:
        continue
    name, expected, observed, status = parts
    services.append(
        {
            "name": name,
            "spiffe_id_expected": expected,
            "spiffe_id_observed": observed,
            "status": status,
        }
    )
    if status == "FAIL":
        failures += 1

payload = {
    "services": services,
    "summary": {
        "failures": failures,
    },
}
out_path.parent.mkdir(parents=True, exist_ok=True)
out_path.write_text(json.dumps(payload, indent=2) + "\n")

if failures == 0:
    print(f"[PASS] wrote artifacts/spiffe_validation.json ({len(services)} services, 0 failures)")
    sys.exit(0)

print(f"[FAIL] wrote artifacts/spiffe_validation.json ({len(services)} services, {failures} failures)")
sys.exit(1)
PY
rc_final=$?
if [ "$rc_final" -eq 10 ]; then
  exit 10
fi
if [ "$rc_final" -eq 0 ]; then
  python3 - "$MATRIX_PATH" <<'PY'
import json
import pathlib
import sys

matrix_path = pathlib.Path(sys.argv[1])
matrix = json.loads(matrix_path.read_text())
services = matrix.get("services", [])
if isinstance(services, list):
    for svc in services:
        if isinstance(svc, dict):
            svc["identity_source"] = "envoy"
    matrix_path.write_text(json.dumps(matrix, indent=2) + "\n")
PY
  exit 0
fi
exit 2
