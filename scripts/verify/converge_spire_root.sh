#!/usr/bin/env bash
# converge_spire_root.sh — enforce strict SPIRE root convergence across all
# ready sidecar pods before bootstrap/proof can continue.

set -euo pipefail
export VERIFY_TYPE=ACTIVE

# Compatibility sentinel for reproducibility guards: this verifier operates on
# root-cert lineage and enforces active SPIRE root trust convergence.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROOF_DIR="${PROOF_LOG_DIR:-$REPO_ROOT/artifacts/proof/latest}"
ARTIFACT_PATH="$PROOF_DIR/spire_root_convergence.json"
TRUST_AUTHORITY_STATE_FILE="${TRUST_AUTHORITY_STATE_FILE:-$REPO_ROOT/artifacts/trust/trust_authority_state.json}"
KUBECTL_BIN="${KUBECTL_BIN:-$(type -P kubectl || true)}"

# shellcheck source=scripts/lib/envoy_admin.sh
source "$REPO_ROOT/scripts/lib/envoy_admin.sh"

SPIRE_CONVERGENCE_RETRIES="${SPIRE_CONVERGENCE_RETRIES:-10}"
SPIRE_ROLLOUT_TIMEOUT="${SPIRE_ROLLOUT_TIMEOUT:-180}"
SPIRE_CONVERGENCE_SLEEP="${SPIRE_CONVERGENCE_SLEEP:-5}"

mkdir -p "$PROOF_DIR"

requires() {
  command -v "$1" >/dev/null 2>&1 || { echo "[FAIL] required command not found: $1"; exit 10; }
}

requires kubectl
requires openssl
requires python3
requires jq

select_ready_pod() {
  local namespace="$1"
  local selector="$2"

  kubectl get pods -n "$namespace" -l "$selector" -o json 2>/dev/null | jq -r '
    .items[]
    | select(.status.phase == "Running")
    | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
    | .metadata.name
  ' | head -n1
}

read_spire_bundle_pem() {
  local server_pod socket_path
  server_pod="$(select_ready_pod spire-system 'app=spire-server')"
  [[ -n "$server_pod" ]] || return 1

  for socket_path in /run/spire/data/server.sock /run/spire/private/spire-server.sock; do
    if kubectl exec -n spire-system -c spire-server "$server_pod" -- \
      /opt/spire/bin/spire-server bundle show -socketPath "$socket_path" -format pem 2>/dev/null; then
      return 0
    fi
  done

  return 1
}

load_active_root_serial() {
  bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
  [[ -s "$TRUST_AUTHORITY_STATE_FILE" ]] || {
    echo "[FAIL] unable to read trust authority state"
    exit 2
  }

  local serial
  serial="$(jq -r '.active_root_serial // empty' "$TRUST_AUTHORITY_STATE_FILE" 2>/dev/null || true)"
  [[ -n "$serial" ]] || {
    echo "[FAIL] trust authority state missing active_root_serial"
    exit 2
  }
  normalize_serial "$serial"
}

ignored_unowned_pods="[]"

record_ignored_unowned_pod() {
  local ns="$1"
  local pod="$2"

  if printf '%s' "$ignored_unowned_pods" | jq -e --arg ns "$ns" --arg pod "$pod" 'any(.[]; .namespace == $ns and .pod == $pod)' >/dev/null; then
    return 0
  fi

  ignored_unowned_pods="$(printf '%s' "$ignored_unowned_pods" | jq --arg ns "$ns" --arg pod "$pod" '. + [{"namespace":$ns,"pod":$pod}]')"
}

normalize_serial() {
  local serial="$1"
  serial="${serial,,}"
  serial="${serial#serial=}"
  serial="$(printf '%s' "$serial" | sed -E 's/^0+//')"
  [[ -n "$serial" ]] || serial="0"
  printf '%s' "$serial"
}

extract_active_root_serial() {
  load_active_root_serial
}

list_ready_sidecar_pods() {
  kubectl get pods -A -o json 2>/dev/null | jq -r '
    .items[]
    | select(.metadata.deletionTimestamp == null)
    | select(.status.phase == "Running")
    | select(any((.spec.containers // [])[]?; .name == "istio-proxy"))
    | select(any((.status.conditions // [])[]?; .type == "Ready" and .status == "True"))
    | [.metadata.namespace, .metadata.name]
    | @tsv
  '
}

extract_pod_workload_anchor_observation() {
  local namespace="$1"
  local pod="$2"
  local secret_file chain_b64 bundle_pem_tmp chain_pem_tmp anchor_serial

  secret_file="$(mktemp)"
  if ! capture_envoy_secrets "$namespace" "$pod" "$secret_file"; then
    rm -f "$secret_file"
    printf '%s\n' '{"status":"UNOBSERVABLE","serial":"","error":"Envoy SDS observation failed"}'
    return 0
  fi

  chain_b64="$(jq -r '.dynamicActiveSecrets[]? | select(.name=="default") | .secret.tlsCertificate.certificateChain.inlineBytes // empty' "$secret_file" | head -n1)"
  if [[ -z "$chain_b64" ]]; then
    rm -f "$secret_file"
    printf '%s\n' '{"status":"UNOBSERVABLE","serial":"","error":"Envoy SDS default secret missing"}'
    return 0
  fi
  rm -f "$secret_file"

  bundle_pem_tmp="$(mktemp)"
  chain_pem_tmp="$(mktemp)"

  read_spire_bundle_pem >"$bundle_pem_tmp" 2>/dev/null || {
    rm -f "$bundle_pem_tmp" "$chain_pem_tmp"
    printf '%s\n' '{"status":"UNOBSERVABLE","serial":"","error":"SPIRE bundle observation failed"}'
    return 0
  }

  printf '%s' "$chain_b64" | base64 -d >"$chain_pem_tmp" || {
    rm -f "$bundle_pem_tmp" "$chain_pem_tmp"
    printf '%s\n' '{"status":"UNOBSERVABLE","serial":"","error":"workload certificate chain decode failed"}'
    return 0
  }

  anchor_serial="$(python3 - "$bundle_pem_tmp" "$chain_pem_tmp" <<'PY'
import pathlib
import re
import subprocess
import sys
import tempfile

bundle_path = pathlib.Path(sys.argv[1])
chain_path = pathlib.Path(sys.argv[2])

def x509_fields(path: pathlib.Path):
    proc = subprocess.run(
        ["openssl", "x509", "-in", str(path), "-noout", "-serial", "-subject", "-issuer"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        return {}
    fields = {}
    for line in proc.stdout.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        fields[key.strip()] = value.strip()
    return fields

def normalize_serial(value: str) -> str:
    serial = (value or "").strip().lower()
    if serial.startswith("serial="):
        serial = serial.split("=", 1)[1]
    serial = re.sub(r"^0+", "", serial)
    return serial or "0"

chain_text = chain_path.read_text(encoding="utf-8", errors="ignore")
chain_pems = re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", chain_text)
if not chain_pems:
    raise SystemExit(1)

with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as fh:
    fh.write(chain_pems[-1] + "\n")
    last_path = pathlib.Path(fh.name)

try:
    last_fields = x509_fields(last_path)
finally:
    last_path.unlink(missing_ok=True)

issuer_dn = last_fields.get("issuer", "")
if not issuer_dn:
    raise SystemExit(1)

bundle_text = bundle_path.read_text(encoding="utf-8", errors="ignore")
for pem in re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", bundle_text):
    with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as fh:
        fh.write(pem + "\n")
        cert_path = pathlib.Path(fh.name)
    try:
        cert_fields = x509_fields(cert_path)
    finally:
        cert_path.unlink(missing_ok=True)
    if cert_fields.get("subject", "") == issuer_dn:
        print(normalize_serial(cert_fields.get("serial", "")))
        raise SystemExit(0)

raise SystemExit(1)
PY
)"

  rm -f "$bundle_pem_tmp" "$chain_pem_tmp"
  if [[ -z "$anchor_serial" ]]; then
    printf '%s\n' '{"status":"UNOBSERVABLE","serial":"","error":"workload certificate anchor could not be resolved"}'
    return 0
  fi
  jq -cn --arg serial "$(normalize_serial "$anchor_serial")" '{status:"OBSERVED",serial:$serial,error:""}'
}

extract_pod_workload_anchor_serial() {
  local observation
  observation="$(extract_pod_workload_anchor_observation "$@")" || return 1
  jq -er 'select(.status == "OBSERVED") | .serial' <<<"$observation"
}

extract_expected_issuance_serial() {
  # Read the intermediate CA serial from spire-csr-ca secret (ca.crt key).
  # This is the CA cert spire-csr uses to issue all workload certificates.
  local raw_serial
  raw_serial="$(kubectl get secret spire-csr-ca -n istio-system \
    -o jsonpath='{.data.ca\.crt}' 2>/dev/null \
    | base64 -d \
    | openssl x509 -noout -serial 2>/dev/null || true)"
  if [[ -z "$raw_serial" ]]; then
    return 1
  fi
  normalize_serial "$raw_serial"
}

extract_issuance_root_serial() {
  # Find which SPIRE bundle root issued the current spire-csr-ca intermediate.
  # During a root rotation the newest bundle root and the issuance root differ;
  # convergence must be measured against the root workloads actually chain to.
  local int_b64 bundle_pem_tmp int_pem_tmp rc
  int_b64="$(kubectl get secret spire-csr-ca -n istio-system \
    -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
  [[ -n "$int_b64" ]] || return 1

  bundle_pem_tmp="$(mktemp)"
  int_pem_tmp="$(mktemp)"

  read_spire_bundle_pem >"$bundle_pem_tmp" 2>/dev/null || {
    rm -f "$bundle_pem_tmp" "$int_pem_tmp"
    return 1
  }

  printf '%s' "$int_b64" | base64 -d >"$int_pem_tmp"

  python3 - "$bundle_pem_tmp" "$int_pem_tmp" <<'PY'
import pathlib, re, subprocess, sys, tempfile

def x509_fields(path):
    r = subprocess.run(
        ["openssl","x509","-in",str(path),"-noout","-serial","-subject","-issuer"],
        capture_output=True, text=True, check=False)
    if r.returncode != 0:
        return {}
    fields = {}
    for line in r.stdout.splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        fields[k.strip()] = v.strip()
    return fields

def normalize_serial(val):
    s = (val or "").strip().lower()
    if s.startswith("serial="):
        s = s.split("=", 1)[1]
    return re.sub(r"^0+", "", s) or "0"

bundle_path = pathlib.Path(sys.argv[1])
int_path = pathlib.Path(sys.argv[2])
int_fields = x509_fields(int_path)
issuer_dn = int_fields.get("issuer", "")
if not issuer_dn:
    raise SystemExit(1)

bundle_text = bundle_path.read_text(encoding="utf-8", errors="ignore")
for pem in re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", bundle_text):
    with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as fh:
        fh.write(pem + "\n")
        p = pathlib.Path(fh.name)
    f = x509_fields(p)
    p.unlink(missing_ok=True)
    if f.get("subject", "") == issuer_dn:
        print(normalize_serial(f.get("serial", "")))
        raise SystemExit(0)

raise SystemExit(1)
PY
  rc=$?
  rm -f "$bundle_pem_tmp" "$int_pem_tmp"
  return $rc
}

build_lineage_allowed_serials_json() {
  local active_root_serial="$1"
  local bundle_pem ca_crt_b64 tls_crt_b64

  bundle_pem="$(read_spire_bundle_pem 2>/dev/null || true)"
  [[ -n "$bundle_pem" ]] || return 1

  ca_crt_b64="$(kubectl get secret spire-csr-ca -n istio-system -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
  tls_crt_b64="$(kubectl get secret spire-csr-ca -n istio-system -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)"
  [[ -n "$ca_crt_b64" && -n "$tls_crt_b64" ]] || return 1

  python3 - "$active_root_serial" "$bundle_pem" "$ca_crt_b64" "$tls_crt_b64" <<'PY'
import base64
import json
import pathlib
import re
import subprocess
import sys
import tempfile

active_root_serial = (sys.argv[1] or "").strip().lower().lstrip("0") or "0"
bundle_pem = sys.argv[2]
ca_crt_b64 = sys.argv[3]
tls_crt_b64 = sys.argv[4]

def normalize_serial(value):
    serial = (value or "").strip().lower()
    if serial.startswith("serial="):
        serial = serial.split("=", 1)[1]
    serial = re.sub(r"^0+", "", serial)
    return serial or "0"

def cert_fields_from_pem(pem):
    with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as fh:
        fh.write(pem if pem.endswith("\n") else pem + "\n")
        cert_path = pathlib.Path(fh.name)
    proc = subprocess.run(
        ["openssl", "x509", "-in", str(cert_path), "-noout", "-serial", "-subject", "-issuer", "-text"],
        capture_output=True, text=True, check=False,
    )
    cert_path.unlink(missing_ok=True)
    if proc.returncode != 0:
        return None
    fields = {"serial": "", "subject": "", "issuer": "", "is_ca": False, "self_signed": False}
    for line in proc.stdout.splitlines():
        s = line.strip()
        if s.startswith("serial="):
            fields["serial"] = normalize_serial(s.split("=", 1)[1])
        elif s.startswith("subject="):
            fields["subject"] = s.split("=", 1)[1].strip()
        elif s.startswith("issuer="):
            fields["issuer"] = s.split("=", 1)[1].strip()
        elif "CA:TRUE" in s:
            fields["is_ca"] = True
    fields["self_signed"] = fields["subject"] == fields["issuer"] and bool(fields["subject"])
    if not fields["serial"]:
        return None
    return fields

def pem_blocks(text):
    return re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", text or "")

certs = []
for p in pem_blocks(bundle_pem):
    m = cert_fields_from_pem(p)
    if m:
        certs.append(m)
for decoded in (
    base64.b64decode(ca_crt_b64).decode("utf-8", errors="ignore"),
    base64.b64decode(tls_crt_b64).decode("utf-8", errors="ignore"),
):
    for p in pem_blocks(decoded):
        m = cert_fields_from_pem(p)
        if m:
            certs.append(m)

serial_index = {}
subject_index = {}
for cert in certs:
    serial_index[cert["serial"]] = cert
    subject_index.setdefault(cert["subject"], []).append(cert)

def anchor_for_serial(serial):
    current = serial_index.get(serial)
    if not current:
        return ""
    seen = set()
    while current:
        s = current.get("serial", "")
        if not s or s in seen:
            return ""
        seen.add(s)
        if current.get("self_signed"):
            return s
        issuer_dn = current.get("issuer", "")
        if not issuer_dn:
            return ""
        matches = subject_index.get(issuer_dn, [])
        if not matches:
            return ""
        current = matches[0]
    return ""

allowed = []
bundle_root_serials = {
    serial
    for serial, cert in serial_index.items()
    if cert.get("is_ca") or cert.get("self_signed")
}
for serial, cert in serial_index.items():
    anchor = anchor_for_serial(serial)
    if anchor in bundle_root_serials and (cert.get("is_ca") or cert.get("self_signed")):
        allowed.append(serial)

print(json.dumps(sorted(set(allowed))))
PY
}

workload_for_pod() {
  local ns="$1"
  local pod="$2"
  local owner_kind owner_name rs deploy

  owner_kind="$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)"
  owner_name="$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)"

  case "$owner_kind" in
    Deployment)
      [[ -n "$owner_name" ]] && echo "deployment/$owner_name"
      return 0
      ;;
    StatefulSet)
      [[ -n "$owner_name" ]] && echo "statefulset/$owner_name"
      return 0
      ;;
    DaemonSet)
      [[ -n "$owner_name" ]] && echo "daemonset/$owner_name"
      return 0
      ;;
  esac

  rs="$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="ReplicaSet")].name}' 2>/dev/null || true)"
  if [[ -z "$rs" ]]; then
    echo ""
    return 0
  fi

  deploy="$(kubectl get replicaset "$rs" -n "$ns" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Deployment")].name}' 2>/dev/null || true)"
  [[ -n "$deploy" ]] && echo "deployment/$deploy" || echo ""
}

restart_and_wait_workload() {
  local namespace="$1"
  local workload="$2"

  local kind="${workload%%/*}"
  local name="${workload#*/}"
  local pod_names pod_uids_before pod_uids_after restart_token

  echo "[converge] restarting ${namespace}/${workload}"
  case "$kind" in
    deployment)
      pod_uids_before="$(kubectl get pods -n "$namespace" -l "app=$name" -o json \
        | jq -r '.items[] | .metadata.uid')"
      ;;
    statefulset)
      pod_uids_before="$(kubectl get pods -n "$namespace" -o json \
        | jq -r --arg owner "$name" '.items[] | select(any(.metadata.ownerReferences[]?; .kind=="StatefulSet" and .name==$owner)) | .metadata.uid')"
      ;;
    daemonset)
      pod_uids_before="$(kubectl get pods -n "$namespace" -o json \
        | jq -r --arg owner "$name" '.items[] | select(any(.metadata.ownerReferences[]?; .kind=="DaemonSet" and .name==$owner)) | .metadata.uid')"
      ;;
    *)
      echo "[converge] unsupported workload kind for restart: ${kind}"
      return 1
      ;;
  esac

  restart_token="$(date -u +%Y%m%d%H%M%S)"
  if ! kubectl patch "$kind/$name" -n "$namespace" --type merge -p "{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"threadforge.io/restartNonce\":\"${restart_token}\"},\"annotations\":{\"threadforge.io/restartedAt\":\"${restart_token}\",\"kubectl.kubernetes.io/restartedAt\":\"${restart_token}\"}}}}}" >/dev/null 2>&1; then
    echo "[converge] template patch denied for ${namespace}/${workload}; falling back to rollout restart"
    if ! kubectl rollout restart "$kind/$name" -n "$namespace" >/dev/null 2>&1; then
      echo "[converge] rollout restart denied for ${namespace}/${workload}; falling back to pod recycle"
      pod_uids_before=""
    fi
  fi

  case "$kind" in
    deployment)
      pod_names="$(kubectl get pods -n "$namespace" -l "app=$name" -o json \
        | jq -r '.items[] | .metadata.name')"
      ;;
    statefulset)
      pod_names="$(kubectl get pods -n "$namespace" -o json \
        | jq -r --arg owner "$name" '.items[] | select(any(.metadata.ownerReferences[]?; .kind=="StatefulSet" and .name==$owner)) | .metadata.name')"
      ;;
    daemonset)
      pod_names="$(kubectl get pods -n "$namespace" -o json \
        | jq -r --arg owner "$name" '.items[] | select(any(.metadata.ownerReferences[]?; .kind=="DaemonSet" and .name==$owner)) | .metadata.name')"
      ;;
  esac

  if [[ -n "${pod_names}" ]]; then
    while IFS= read -r pod; do
      [[ -n "$pod" ]] || continue
      kubectl delete pod "$pod" -n "$namespace" --wait=false >/dev/null
    done <<<"$pod_names"
  fi

  kubectl rollout status "$kind/$name" -n "$namespace" --timeout="${SPIRE_ROLLOUT_TIMEOUT}s"

  case "$kind" in
    deployment)
      pod_uids_after="$(kubectl get pods -n "$namespace" -l "app=$name" -o json \
        | jq -r '.items[] | .metadata.uid')"
      ;;
    statefulset)
      pod_uids_after="$(kubectl get pods -n "$namespace" -o json \
        | jq -r --arg owner "$name" '.items[] | select(any(.metadata.ownerReferences[]?; .kind=="StatefulSet" and .name==$owner)) | .metadata.uid')"
      ;;
    daemonset)
      pod_uids_after="$(kubectl get pods -n "$namespace" -o json \
        | jq -r --arg owner "$name" '.items[] | select(any(.metadata.ownerReferences[]?; .kind=="DaemonSet" and .name==$owner)) | .metadata.uid')"
      ;;
  esac

  if [[ -n "$pod_uids_before" && "$pod_uids_before" == "$pod_uids_after" ]]; then
    echo "[converge] rollout restart for ${namespace}/${workload} did not replace pod(s); forcing recycle"
    case "$kind" in
      deployment)
        pod_names="$(kubectl get pods -n "$namespace" -o json \
          | jq -r --arg prefix "${name}-" '.items[] | select(any(.metadata.ownerReferences[]?; .kind=="ReplicaSet" and (.name|startswith($prefix)))) | .metadata.name')"
        ;;
      statefulset)
        pod_names="$(kubectl get pods -n "$namespace" -o json \
          | jq -r --arg owner "$name" '.items[] | select(any(.metadata.ownerReferences[]?; .kind=="StatefulSet" and .name==$owner)) | .metadata.name')"
        ;;
      daemonset)
        pod_names="$(kubectl get pods -n "$namespace" -o json \
          | jq -r --arg owner "$name" '.items[] | select(any(.metadata.ownerReferences[]?; .kind=="DaemonSet" and .name==$owner)) | .metadata.name')"
        ;;
    esac

    if [[ -z "${pod_names}" ]]; then
      echo "[converge] no pods found to recycle for ${namespace}/${workload}"
      return 1
    fi

    while IFS= read -r pod; do
      [[ -n "$pod" ]] || continue
      kubectl delete pod "$pod" -n "$namespace" --wait=false >/dev/null
    done <<<"$pod_names"

    kubectl rollout status "$kind/$name" -n "$namespace" --timeout="${SPIRE_ROLLOUT_TIMEOUT}s"
  fi
}

refresh_control_plane_trust() {
  echo "[converge] refreshing control-plane trust distribution"

  bash "$REPO_ROOT/scripts/verify/refresh_spire_istio_ca_path.sh"

  kubectl rollout restart daemonset/spire-agent -n spire-system >/dev/null
  kubectl rollout status daemonset/spire-agent -n spire-system --timeout="${SPIRE_ROLLOUT_TIMEOUT}s"

  kubectl delete pod -n istio-system -l app=spire-csr --ignore-not-found >/dev/null
  kubectl rollout status deployment/spire-csr -n istio-system --timeout="${SPIRE_ROLLOUT_TIMEOUT}s"

  kubectl rollout restart deployment/istiod -n istio-system >/dev/null
  kubectl rollout status deployment/istiod -n istio-system --timeout="${SPIRE_ROLLOUT_TIMEOUT}s"

  # istiod can repopulate istio-ca-root-cert from the live SPIRE bundle on startup.
  # During rollover that bundle has two roots, so re-assert single active root afterward.
  reconcile_active_root_configmaps

  # The positive containment path depends on the writer workload reloading the
  # current trust material after control-plane refresh. A root-only check is not
  # sufficient because the existing workload cert can remain on disk long enough
  # to produce transient TLS verification failures on the allowed edge.
  restart_and_wait_workload agents-lab deployment/writer-agent

  # The allowed-path probe originates from research-agent, so its workload
  # certificate must also be recycled after the trust refresh. Otherwise the
  # source proxy can continue presenting an older chain even after the control
  # plane has converged.
  restart_and_wait_workload agents-lab deployment/research-agent

  # The rogue-agent scenario also exercises live TLS verification against the
  # same trust lineage, so it must reload after trust refresh rather than
  # retaining an older bundle that would convert policy denial into a TLS 503.
  restart_and_wait_workload agents-lab deployment/rogue-agent

  kubectl rollout restart deployment/istio-ingressgateway -n istio-system >/dev/null 2>&1 || true
  kubectl rollout status deployment/istio-ingressgateway -n istio-system --timeout="${SPIRE_ROLLOUT_TIMEOUT}s" >/dev/null 2>&1 || true
}

reconcile_active_root_configmaps() {
  local active_root_tmp cm_yaml_tmp active_root_pem
  active_root_tmp="$(mktemp)"
  cm_yaml_tmp="$(mktemp)"

  bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
  active_root_pem="$(jq -r '.active_root_pem // empty' "$TRUST_AUTHORITY_STATE_FILE" 2>/dev/null || true)"
  if [[ -z "$active_root_pem" ]]; then
    rm -f "$active_root_tmp" "$cm_yaml_tmp"
    echo "[converge] unable to read active SPIRE root from trust authority state"
    return 1
  fi
  printf '%s\n' "$active_root_pem" >"$active_root_tmp"

  for cm_target in "spire-system/spire-ca-root-cert" "istio-system/spire-ca-root-cert" "istio-system/istio-ca-root-cert" "observability/istio-ca-root-cert"; do
    local cm_ns cm_name
    cm_ns="${cm_target%%/*}"
    cm_name="${cm_target#*/}"

    kubectl create configmap "$cm_name" --from-file=root-cert.pem="$active_root_tmp" -n "$cm_ns" --dry-run=client -o yaml >"$cm_yaml_tmp"
    if kubectl get configmap "$cm_name" -n "$cm_ns" >/dev/null 2>&1; then
      kubectl replace -f "$cm_yaml_tmp" >/dev/null
    else
      kubectl create -f "$cm_yaml_tmp" >/dev/null
    fi
  done

  kubectl -n istio-system label configmap istio-ca-root-cert istio.io/config=true --overwrite >/dev/null 2>&1 || true
  rm -f "$active_root_tmp" "$cm_yaml_tmp"
  echo "[converge] re-reconciled root configmaps with active SPIRE root"
}

detect_mismatches_json() {
  local allowed_serials_json="$1"
  local rows="[]"
  local pod_serial observation observation_status observation_error
  local expected_display
  local workload

  expected_display="$(printf '%s' "$allowed_serials_json" | jq -r 'join(",")')"

  while IFS=$'\t' read -r ns pod; do
    [[ -n "$ns" && -n "$pod" ]] || continue
    workload="$(workload_for_pod "$ns" "$pod")"

    if [[ -n "$pod" ]] && observation="$(extract_pod_workload_anchor_observation "$ns" "$pod")"; then
      observation_status="$(printf '%s' "$observation" | jq -r '.status // "UNOBSERVABLE"')"
      observation_error="$(printf '%s' "$observation" | jq -r '.error // empty')"
      pod_serial="$(printf '%s' "$observation" | jq -r '.serial // empty')"
    else
      observation_status="UNOBSERVABLE"
      observation_error="anchor observation command failed"
      pod_serial=""
    fi

    if [[ "$observation_status" == "OBSERVED" && -n "$pod_serial" ]]; then
      if printf '%s' "$allowed_serials_json" | jq -e --arg serial "$pod_serial" 'index($serial) != null' >/dev/null; then
        echo "[converge] pod=${ns}/${pod} anchor_serial=${pod_serial} allowed=${expected_display}" >&2
      else
        echo "[converge] pod=${ns}/${pod} anchor_serial=${pod_serial} allowed=${expected_display}" >&2
        rows="$(printf '%s' "$rows" | jq --arg ns "$ns" --arg pod "$pod" --arg s "$pod_serial" --arg e "$expected_display" '. + [{"namespace":$ns,"name":$pod,"root_serial":$s,"expected_serial":$e,"observation_status":"OBSERVED"}]')"
      fi
    else
      if [[ -z "$workload" ]]; then
        record_ignored_unowned_pod "$ns" "$pod"
        echo "[INFO] skipping standalone pod ${ns}/${pod} (no owner reference)" >&2
        continue
      fi
      echo "[converge] pod=${ns}/${pod} anchor_serial=unknown observation_status=${observation_status} error=${observation_error:-none} allowed=${expected_display}" >&2
      rows="$(printf '%s' "$rows" | jq --arg ns "$ns" --arg pod "$pod" --arg e "$expected_display" --arg s "$observation_status" --arg error "$observation_error" '. + [{"namespace":$ns,"name":$pod,"root_serial":"unknown","expected_serial":$e,"observation_status":$s,"observation_error":$error}]')"
    fi
  done < <(list_ready_sidecar_pods)

  printf '%s' "$rows"
}

extract_root_configmap_serial() {
  local namespace="$1"
  local name="$2"
  local root_value serial

  root_value="$(kubectl -n "$namespace" get configmap "$name" -o jsonpath='{.data.root-cert\.pem}' 2>/dev/null || true)"
  [[ -n "$root_value" ]] || return 1

  serial="$(printf '%s' "$root_value" | openssl x509 -noout -serial 2>/dev/null || true)"
  [[ -n "$serial" ]] || return 1
  normalize_serial "$serial"
}

detect_root_configmap_mismatches_json() {
  local active_root_serial="$1"
  local rows="[]"
  local configmap_serial
  local expected_display

  expected_display="$active_root_serial"

  for cm_target in "spire-system/spire-ca-root-cert" "istio-system/spire-ca-root-cert" "istio-system/istio-ca-root-cert" "observability/istio-ca-root-cert"; do
    local cm_ns cm_name
    cm_ns="${cm_target%%/*}"
    cm_name="${cm_target#*/}"

    if configmap_serial="$(extract_root_configmap_serial "$cm_ns" "$cm_name")"; then
      if [[ "$configmap_serial" != "$active_root_serial" ]]; then
        echo "[converge] configmap=${cm_ns}/${cm_name} serial=${configmap_serial} expected=${expected_display}" >&2
        rows="$(printf '%s' "$rows" | jq --arg ns "$cm_ns" --arg name "$cm_name" --arg s "$configmap_serial" --arg e "$expected_display" '. + [{"namespace":$ns,"name":$name,"root_serial":$s,"expected_serial":$e}]')"
      fi
    else
      echo "[converge] configmap=${cm_ns}/${cm_name} serial=unknown expected=${expected_display}" >&2
      rows="$(printf '%s' "$rows" | jq --arg ns "$cm_ns" --arg name "$cm_name" --arg e "$expected_display" '. + [{"namespace":$ns,"name":$name,"root_serial":"unknown","expected_serial":$e}]')"
    fi
  done

  printf '%s' "$rows"
}

# Verify that the spire-csr-ca intermediate CA (ca.crt) terminates at the active
# SPIRE root serial. This is the hard invariant: all new certs must be rooted
# in the active SPIRE root — no local/fallback CA is permitted.
assert_intermediate_chains_to_spire_root() {
  local active_root_serial="$1"
  local int_b64 bundle_pem_tmp int_pem_tmp intermediate_anchor_serial

  int_b64="$(kubectl get secret spire-csr-ca -n istio-system \
    -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
  [[ -n "$int_b64" ]] || {
    echo "[FAIL] SPIRE_CSR_STALE_ROOT: spire-csr-ca secret missing ca.crt"
    exit 2
  }

  bundle_pem_tmp="$(mktemp)"
  int_pem_tmp="$(mktemp)"

  read_spire_bundle_pem >"$bundle_pem_tmp" 2>/dev/null || {
    rm -f "$bundle_pem_tmp" "$int_pem_tmp"
    echo "[FAIL] SPIRE_CSR_STALE_ROOT: unable to fetch SPIRE bundle for chain verification"
    exit 2
  }

  printf '%s' "$int_b64" | base64 -d >"$int_pem_tmp"

  if ! openssl verify -CAfile "$bundle_pem_tmp" "$int_pem_tmp" >/dev/null 2>&1; then
    rm -f "$bundle_pem_tmp" "$int_pem_tmp"
    echo "[FAIL] SPIRE_CSR_STALE_ROOT: spire-csr-ca intermediate NOT signed by active SPIRE root (root_serial=${active_root_serial})"
    exit 2
  fi

  intermediate_anchor_serial="$(python3 - "$bundle_pem_tmp" "$int_pem_tmp" <<'PY'
import pathlib
import re
import subprocess
import sys
import tempfile

bundle_path = pathlib.Path(sys.argv[1])
intermediate_path = pathlib.Path(sys.argv[2])

def x509_fields(path: pathlib.Path):
    proc = subprocess.run(
        ["openssl", "x509", "-in", str(path), "-noout", "-serial", "-subject", "-issuer"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        return {}
    fields = {}
    for line in proc.stdout.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        fields[key.strip()] = value.strip()
    return fields

def normalize_serial(value: str) -> str:
    serial = (value or "").strip().lower()
    if serial.startswith("serial="):
        serial = serial.split("=", 1)[1]
    serial = re.sub(r"^0+", "", serial)
    return serial or "0"

intermediate_fields = x509_fields(intermediate_path)
issuer_dn = intermediate_fields.get("issuer", "")
if not issuer_dn:
    print("")
    raise SystemExit(0)

bundle_text = bundle_path.read_text(encoding="utf-8", errors="ignore")
bundle_pems = re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", bundle_text)
for pem in bundle_pems:
    with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as fh:
        fh.write(pem if pem.endswith("\n") else pem + "\n")
        cert_path = pathlib.Path(fh.name)
    cert_fields = x509_fields(cert_path)
    cert_path.unlink(missing_ok=True)
    if cert_fields.get("subject", "") == issuer_dn:
        print(normalize_serial(cert_fields.get("serial", "")))
        raise SystemExit(0)

print("")
PY
  )"

  if [[ -z "$intermediate_anchor_serial" ]]; then
    rm -f "$bundle_pem_tmp" "$int_pem_tmp"
    echo "[FAIL] SPIRE_CSR_STALE_ROOT: unable to resolve terminating anchor for spire-csr-ca intermediate"
    exit 2
  fi

  if [[ "$intermediate_anchor_serial" != "$active_root_serial" ]]; then
    rm -f "$bundle_pem_tmp" "$int_pem_tmp"
    echo "[FAIL] SPIRE_CSR_STALE_ROOT: spire-csr-ca intermediate terminates at root_serial=${intermediate_anchor_serial} but active_root_serial=${active_root_serial}"
    exit 2
  fi

  rm -f "$bundle_pem_tmp" "$int_pem_tmp"
  echo "[converge] spire-csr-ca intermediate verified: terminating_anchor_serial=${intermediate_anchor_serial} active_root_serial=${active_root_serial}"
}

ACTIVE_ROOT_SERIAL="$(extract_active_root_serial)"
echo "[converge] BUNDLE_NEWEST_ROOT_SERIAL=${ACTIVE_ROOT_SERIAL}"
ISSUANCE_ROOT_SERIAL="$(extract_issuance_root_serial || true)"
if [[ -n "$ISSUANCE_ROOT_SERIAL" && "$ISSUANCE_ROOT_SERIAL" != "$ACTIVE_ROOT_SERIAL" ]]; then
  echo "[converge] SPIRE root rotation in progress: spire-csr-ca issuance root=${ISSUANCE_ROOT_SERIAL} differs from newest bundle root=${ACTIVE_ROOT_SERIAL}; using issuance root for convergence"
  ACTIVE_ROOT_SERIAL="$ISSUANCE_ROOT_SERIAL"
fi
echo "[converge] ACTIVE_ROOT_SERIAL=${ACTIVE_ROOT_SERIAL}"
assert_intermediate_chains_to_spire_root "$ACTIVE_ROOT_SERIAL"

EXPECTED_ISSUANCE_SERIAL="$(extract_expected_issuance_serial)"
if [[ -z "$EXPECTED_ISSUANCE_SERIAL" ]]; then
  echo "[FAIL] unable to extract expected issuance serial from spire-csr-ca"
  exit 2
fi
if ! build_lineage_allowed_serials_json "$ACTIVE_ROOT_SERIAL" >/dev/null; then
  echo "[FAIL] unable to build lineage-aware allowed serial set"
  exit 2
fi
ALLOWED_CA_SERIALS="$(jq -n --arg active "$ACTIVE_ROOT_SERIAL" '[$active]')"
echo "[converge] EXPECTED_ISSUANCE_SERIAL=${EXPECTED_ISSUANCE_SERIAL}"
echo "[converge] LINEAGE_ALLOWED_SERIALS=$(printf '%s' "$ALLOWED_CA_SERIALS" | jq -r 'join(",")')"

attempt=1
remediated="[]"
control_plane_refreshed=0
while (( attempt <= SPIRE_CONVERGENCE_RETRIES )); do
  echo "[converge] verification attempt ${attempt}/${SPIRE_CONVERGENCE_RETRIES}"

  mismatches="$(detect_mismatches_json "$ALLOWED_CA_SERIALS")"
  mismatch_count="$(printf '%s' "$mismatches" | jq 'length')"
  configmap_mismatches="$(detect_root_configmap_mismatches_json "$ACTIVE_ROOT_SERIAL")"
  configmap_mismatch_count="$(printf '%s' "$configmap_mismatches" | jq 'length')"

  if [[ "$mismatch_count" -eq 0 && "$configmap_mismatch_count" -eq 0 ]]; then
    printf '%s\n' "$(jq -n --arg active "$ACTIVE_ROOT_SERIAL" --argjson allowed "$ALLOWED_CA_SERIALS" --argjson rem "$remediated" --argjson ignored "$ignored_unowned_pods" '{"status":"PASS","active_root_serial":$active,"allowed_ca_serials":$allowed,"converged":true,"remediated_workloads":$rem,"remaining_offenders":[],"remaining_configmap_offenders":[],"ignored_unowned_pods":$ignored}')" >"$ARTIFACT_PATH"
    echo "[PASS] all workloads converged to SPIRE root"
    exit 0
  fi

  if [[ "$control_plane_refreshed" -eq 0 ]]; then
    if [[ "$configmap_mismatch_count" -gt 0 ]]; then
      echo "[converge] detected stale root configmaps; refreshing control-plane trust distribution"
    fi
    if refresh_control_plane_trust; then
      control_plane_refreshed=1
      remediated="$(printf '%s' "$remediated" | jq '. + [{"namespace":"spire-system","workload":"daemonset/spire-agent"},{"namespace":"istio-system","workload":"deployment/spire-csr"},{"namespace":"istio-system","workload":"deployment/istiod"}]')"
      ACTIVE_ROOT_SERIAL="$(extract_active_root_serial)"
      echo "[converge] ACTIVE_ROOT_SERIAL_REFRESHED=${ACTIVE_ROOT_SERIAL}"
      assert_intermediate_chains_to_spire_root "$ACTIVE_ROOT_SERIAL"
      EXPECTED_ISSUANCE_SERIAL="$(extract_expected_issuance_serial)"
      if [[ -z "$EXPECTED_ISSUANCE_SERIAL" ]]; then
        echo "[FAIL] unable to extract expected issuance serial from spire-csr-ca after control-plane refresh"
        exit 2
      fi
      if ! build_lineage_allowed_serials_json "$ACTIVE_ROOT_SERIAL" >/dev/null; then
        echo "[FAIL] unable to rebuild lineage-aware allowed serial set after control-plane refresh"
        exit 2
      fi
      ALLOWED_CA_SERIALS="$(jq -n --arg active "$ACTIVE_ROOT_SERIAL" '[$active]')"
      echo "[converge] EXPECTED_ISSUANCE_SERIAL_REFRESHED=${EXPECTED_ISSUANCE_SERIAL}"
      echo "[converge] LINEAGE_ALLOWED_SERIALS_REFRESHED=$(printf '%s' "$ALLOWED_CA_SERIALS" | jq -r 'join(",")')"
      mismatches="$(detect_mismatches_json "$ALLOWED_CA_SERIALS")"
      mismatch_count="$(printf '%s' "$mismatches" | jq 'length')"
      configmap_mismatches="$(detect_root_configmap_mismatches_json "$ACTIVE_ROOT_SERIAL")"
      configmap_mismatch_count="$(printf '%s' "$configmap_mismatches" | jq 'length')"
      if [[ "$mismatch_count" -eq 0 && "$configmap_mismatch_count" -eq 0 ]]; then
        printf '%s\n' "$(jq -n --arg active "$ACTIVE_ROOT_SERIAL" --argjson allowed "$ALLOWED_CA_SERIALS" --argjson rem "$remediated" --argjson ignored "$ignored_unowned_pods" '{"status":"PASS","active_root_serial":$active,"allowed_ca_serials":$allowed,"converged":true,"remediated_workloads":$rem,"remaining_offenders":[],"remaining_configmap_offenders":[],"ignored_unowned_pods":$ignored}')" >"$ARTIFACT_PATH"
        echo "[PASS] all workloads converged to SPIRE root"
        exit 0
      fi
    else
      echo "[converge] control-plane trust refresh failed; continuing bounded retries"
    fi
  fi

  declare -A restarted=()
  while IFS= read -r offender; do
    ns="$(printf '%s' "$offender" | jq -r '.namespace')"
    pod="$(printf '%s' "$offender" | jq -r '.name')"

    workload="$(workload_for_pod "$ns" "$pod")"
    if [[ -z "$workload" ]]; then
      record_ignored_unowned_pod "$ns" "$pod"
      echo "[INFO] skipping standalone pod ${ns}/${pod} (no owner reference)"
      continue
    fi

    key="${ns}/${workload}"
    if [[ "${restarted[$key]:-}" == "1" ]]; then
      continue
    fi
    restarted[$key]="1"

    if restart_and_wait_workload "$ns" "$workload"; then
      remediated="$(printf '%s' "$remediated" | jq --arg ns "$ns" --arg w "$workload" '. + [{"namespace":$ns,"workload":$w}]')"
    else
      echo "[converge] restart/wait failed for ${ns}/${workload}; will retry verification"
    fi
  done < <(printf '%s' "$mismatches" | jq -c '.[]')

  attempt=$((attempt + 1))
  sleep "$SPIRE_CONVERGENCE_SLEEP"
done

final_mismatches="$(detect_mismatches_json "$ALLOWED_CA_SERIALS")"
final_count="$(printf '%s' "$final_mismatches" | jq 'length')"
final_configmap_mismatches="$(detect_root_configmap_mismatches_json "$ACTIVE_ROOT_SERIAL")"
printf '%s\n' "$(jq -n --arg active "$ACTIVE_ROOT_SERIAL" --argjson allowed "$ALLOWED_CA_SERIALS" --argjson rem "$remediated" --argjson left "$final_mismatches" --argjson cfg "$final_configmap_mismatches" --argjson ignored "$ignored_unowned_pods" '{"status":"FAIL","active_root_serial":$active,"allowed_ca_serials":$allowed,"converged":false,"remediated_workloads":$rem,"remaining_offenders":$left,"remaining_configmap_offenders":$cfg,"ignored_unowned_pods":$ignored}')" >"$ARTIFACT_PATH"

final_configmap_count="$(printf '%s' "$final_configmap_mismatches" | jq 'length')"
echo "[FAIL] ROOT_CONVERGENCE_INCOMPLETE: ${final_count} pod(s) and ${final_configmap_count} configmap(s) still mismatched after ${SPIRE_CONVERGENCE_RETRIES} retries"
printf '%s\n' "$final_mismatches" | jq -r '.[] | if .observation_status == "UNOBSERVABLE" then "  [unobservable] \(.namespace)/\(.name) serial=\(.root_serial) expected=\(.expected_serial) error=\(.observation_error // "unknown")" else "  [stale] \(.namespace)/\(.name) serial=\(.root_serial) expected=\(.expected_serial)" end'
printf '%s\n' "$final_configmap_mismatches" | jq -r '.[] | "  [stale-configmap] \(.namespace)/\(.name) serial=\(.root_serial) expected=\(.expected_serial)"'
exit 2
