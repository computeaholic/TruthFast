#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_PATH="${1:-${CA_DEBUG_OUTPUT_PATH:-$REPO_ROOT/artifacts/debug/ca_source_debug.log}}"
DEBUG_DIR="$(dirname "$OUT_PATH")"
KUBECTL_BIN="${KUBECTL_BIN:-$(type -P kubectl || true)}"
ISTIOCTL_BIN="${ISTIOCTL_BIN:-$(type -P istioctl || true)}"
PYTHON_BIN="${PYTHON_BIN:-$(type -P python3 || true)}"

run_kubectl() {
  if [ -z "$KUBECTL_BIN" ]; then
    echo "[FAIL] kubectl binary not found" >&2
    exit 2
  fi
  "$KUBECTL_BIN" "$@"
}

run_istioctl() {
  if [ -z "$ISTIOCTL_BIN" ]; then
    echo "[FAIL] istioctl binary not found" >&2
    exit 2
  fi
  "$ISTIOCTL_BIN" "$@"
}

mkdir -p "$DEBUG_DIR"

ISTIOD_SDS_RAW="$DEBUG_DIR/istiod_sds_debug.txt"
ISTIOD_LOGS_RAW="$DEBUG_DIR/istiod_logs_debug.txt"
GATEWAY_CERTS_RAW="$DEBUG_DIR/gateway_envoy_certs.json"
GATEWAY_PROXY_SECRET_RAW="$DEBUG_DIR/gateway_proxy_secret.json"
SPIRE_BUNDLE_RAW="$DEBUG_DIR/spire_bundle.pem"
ISTIO_SECRETS_RAW="$DEBUG_DIR/istio_secrets.txt"
SPIRE_ROOT_MATCH_PEM="$DEBUG_DIR/spire_root_from_bundle.pem"
ENVOY_ROOT_PEM="$DEBUG_DIR/envoy_root_from_secret.pem"
ROOT_COMPARE_JSON="$DEBUG_DIR/ca_root_compare.json"
SPIRE_BUNDLE_DUMP_LOG="$DEBUG_DIR/spire_bundle_dump.log"
WORKLOAD_CHAIN_LOG="$DEBUG_DIR/workload_cert_chain.log"
WORKLOAD_CERTS_RAW="$DEBUG_DIR/workload_envoy_certs.json"

GATEWAY_POD="$(run_kubectl -n istio-system get pod -l app=istio-ingressgateway -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1)"
SPIRE_SERVER_POD="$(run_kubectl -n spire-system get pod -l app=spire-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
WORKLOAD_POD="$(run_kubectl -n threadforge-test get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [ -n "$GATEWAY_POD" ]; then
  run_kubectl -n istio-system exec deploy/istiod -- curl -s localhost:15014/debug/sds > "$ISTIOD_SDS_RAW" 2>&1 || true
  run_kubectl -n istio-system logs deploy/istiod --tail=200 > "$ISTIOD_LOGS_RAW" 2>&1 || true
  run_kubectl -n istio-system exec deploy/istio-ingressgateway -c istio-proxy -- curl -s localhost:15000/certs > "$GATEWAY_CERTS_RAW" 2>&1 || true
  run_istioctl proxy-config secret "$GATEWAY_POD" -n istio-system -o json > "$GATEWAY_PROXY_SECRET_RAW" 2>&1 || true
else
  printf 'gateway pod unavailable\n' > "$GATEWAY_CERTS_RAW"
  printf 'gateway pod unavailable\n' > "$GATEWAY_PROXY_SECRET_RAW"
  run_kubectl -n istio-system exec deploy/istiod -- curl -s localhost:15014/debug/sds > "$ISTIOD_SDS_RAW" 2>&1 || true
  run_kubectl -n istio-system logs deploy/istiod --tail=200 > "$ISTIOD_LOGS_RAW" 2>&1 || true
fi

if [ -n "$SPIRE_SERVER_POD" ]; then
  run_kubectl -n spire-system exec "$SPIRE_SERVER_POD" -- /opt/spire/bin/spire-server bundle show -format pem -socketPath /run/spire/private/spire-server.sock > "$SPIRE_BUNDLE_RAW" 2>&1 || true
else
  printf 'spire-server pod unavailable\n' > "$SPIRE_BUNDLE_RAW"
fi

if [ -n "$WORKLOAD_POD" ]; then
  run_kubectl -n threadforge-test exec "$WORKLOAD_POD" -c istio-proxy -- curl -s localhost:15000/certs > "$WORKLOAD_CERTS_RAW" 2>&1 || true
else
  printf 'workload pod unavailable\n' > "$WORKLOAD_CERTS_RAW"
fi

run_kubectl -n istio-system get secrets > "$ISTIO_SECRETS_RAW" 2>&1 || true

{
  echo "=== spire bundle raw ==="
  cat "$SPIRE_BUNDLE_RAW"
  echo
  echo "=== parsed roots ==="
  awk -v debug_dir="$DEBUG_DIR" 'BEGIN{n=0} /-----BEGIN CERTIFICATE-----/{n++; file=sprintf("%s/spire-bundle-root-%02d.pem", debug_dir, n)} {if(file) print > file} /-----END CERTIFICATE-----/{close(file); file=""}' "$SPIRE_BUNDLE_RAW"
  for pem in "$DEBUG_DIR"/spire-bundle-root-*.pem; do
    [ -f "$pem" ] || continue
    echo
    echo "--- $pem ---"
    openssl x509 -in "$pem" -noout -subject -issuer -serial -startdate -enddate || true
    if openssl x509 -checkend 0 -noout -in "$pem" >/dev/null 2>&1; then
      echo "status=currently-valid"
    else
      echo "status=expired-or-not-yet-valid"
    fi
  done
} > "$SPIRE_BUNDLE_DUMP_LOG"

{
  echo "=== workload envoy cert dump ==="
  cat "$WORKLOAD_CERTS_RAW"
  echo
  echo "=== proxy-config secret summary ==="
  if [ -n "$WORKLOAD_POD" ]; then
    run_istioctl proxy-config secret "$WORKLOAD_POD" -n threadforge-test -o json || true
  else
    echo "workload pod unavailable"
  fi
} > "$WORKLOAD_CHAIN_LOG"

if [ -n "$PYTHON_BIN" ] && [ -s "$GATEWAY_CERTS_RAW" ] && [ -s "$GATEWAY_PROXY_SECRET_RAW" ] && [ -s "$SPIRE_BUNDLE_RAW" ]; then
  "$PYTHON_BIN" - "$GATEWAY_CERTS_RAW" "$GATEWAY_PROXY_SECRET_RAW" "$SPIRE_BUNDLE_RAW" "$ENVOY_ROOT_PEM" "$SPIRE_ROOT_MATCH_PEM" "$ROOT_COMPARE_JSON" <<'PY' || true
import base64
import hashlib
import json
import pathlib
import re
import ssl
import subprocess
import sys
import tempfile

gateway_certs_path = pathlib.Path(sys.argv[1])
proxy_secret_path = pathlib.Path(sys.argv[2])
spire_bundle_path = pathlib.Path(sys.argv[3])
envoy_root_out = pathlib.Path(sys.argv[4])
spire_root_out = pathlib.Path(sys.argv[5])
compare_out = pathlib.Path(sys.argv[6])


def extract_pems(text: str):
    return [match.strip() + "\n" for match in re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", text)]


def pem_fingerprint(pem: str) -> str:
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest()


def pem_serial(pem: str) -> str:
    with tempfile.NamedTemporaryFile("w", delete=False) as handle:
        handle.write(pem)
        cert_path = handle.name
    try:
        proc = subprocess.run(["openssl", "x509", "-in", cert_path, "-noout", "-serial"], capture_output=True, text=True, check=False)
    finally:
        pathlib.Path(cert_path).unlink(missing_ok=True)
    raw = (proc.stdout or "").strip()
    if "=" not in raw:
        return ""
    return raw.split("=", 1)[1].strip().lower().lstrip("0") or "0"


payload = {
    "status": "unavailable",
    "envoy_root_serial": "",
    "envoy_root_fingerprint": "",
    "spire_root_serial": "",
    "spire_root_fingerprint": "",
    "match": False,
    "reason": "insufficient data",
}

try:
    gateway_doc = json.loads(gateway_certs_path.read_text())
    secret_doc = json.loads(proxy_secret_path.read_text())
except Exception:
    compare_out.write_text(json.dumps(payload, indent=2) + "\n")
    raise SystemExit(0)

spiffe_entries = []
for entry in gateway_doc.get("certificates", []) or []:
    if not isinstance(entry, dict):
        continue
    chain = entry.get("cert_chain") or []
    ca_chain = entry.get("ca_cert") or []
    if not chain or not ca_chain:
        continue
    uris = []
    for cert in chain:
        for san in cert.get("subject_alt_names") or []:
            uri = san.get("uri")
            if isinstance(uri, str) and uri.startswith("spiffe://"):
                uris.append(uri)
    if uris:
        spiffe_entries.append((entry, uris))

root_serials = set()
for entry, _ in spiffe_entries:
    for cert in entry.get("ca_cert") or []:
        serial = str(cert.get("serial_number", "")).strip().lower().lstrip("0") or "0"
        if serial:
            root_serials.add(serial)

rootca = next((item for item in (secret_doc.get("dynamicActiveSecrets") or []) if isinstance(item, dict) and item.get("name") == "ROOTCA"), None)
trusted_b64 = (((rootca or {}).get("secret") or {}).get("validationContext") or {}).get("trustedCa", {}).get("inlineBytes")
if isinstance(trusted_b64, str) and trusted_b64:
    trusted_pem = base64.b64decode(trusted_b64).decode("utf-8", errors="ignore")
    trusted_roots = extract_pems(trusted_pem)
else:
    trusted_roots = []

spire_roots = extract_pems(spire_bundle_path.read_text())

matched_spire_root = ""
envoy_root = trusted_roots[0] if len(trusted_roots) == 1 else ""
envoy_serial = pem_serial(envoy_root) if envoy_root else ""
for pem in spire_roots:
    if pem_serial(pem) == envoy_serial:
        matched_spire_root = pem
        break

if envoy_root:
    envoy_root_out.write_text(envoy_root)
if matched_spire_root:
    spire_root_out.write_text(matched_spire_root)

payload = {
    "status": "ok",
    "envoy_root_serial": envoy_serial,
    "envoy_root_fingerprint": pem_fingerprint(envoy_root) if envoy_root else "",
    "spire_root_serial": pem_serial(matched_spire_root) if matched_spire_root else "",
    "spire_root_fingerprint": pem_fingerprint(matched_spire_root) if matched_spire_root else "",
    "match": bool(envoy_root and matched_spire_root and pem_fingerprint(envoy_root) == pem_fingerprint(matched_spire_root)),
    "gateway_spiffe_uris": sorted({uri for _, uris in spiffe_entries for uri in uris}),
    "envoy_runtime_root_serials": sorted(root_serials),
}
compare_out.write_text(json.dumps(payload, indent=2) + "\n")
PY
fi

{
  echo "=== istiod cert source ==="
  echo "command: kubectl -n istio-system exec deploy/istiod -- curl -s localhost:15014/debug/sds"
  cat "$ISTIOD_SDS_RAW"
  echo
  echo "=== istiod logs ==="
  echo "command: kubectl -n istio-system logs deploy/istiod --tail=200"
  cat "$ISTIOD_LOGS_RAW"
  echo
  echo "=== gateway cert dump ==="
  echo "command: kubectl -n istio-system exec deploy/istio-ingressgateway -c istio-proxy -- curl -s localhost:15000/certs"
  cat "$GATEWAY_CERTS_RAW"
  echo
  echo "=== gateway proxy secret ==="
  echo "command: istioctl proxy-config secret ${GATEWAY_POD:-<missing>} -n istio-system -o json"
  cat "$GATEWAY_PROXY_SECRET_RAW"
  echo
  echo "=== SPIRE bundle ==="
  echo "command: kubectl -n spire-system exec ${SPIRE_SERVER_POD:-<missing>} -- /opt/spire/bin/spire-server bundle show -format pem -socketPath /run/spire/private/spire-server.sock"
  cat "$SPIRE_BUNDLE_RAW"
  echo
  echo "=== secrets check ==="
  echo "command: kubectl -n istio-system get secrets"
  cat "$ISTIO_SECRETS_RAW"
  echo
  echo "=== root comparison ==="
  if [ -f "$ROOT_COMPARE_JSON" ]; then
    cat "$ROOT_COMPARE_JSON"
  else
    echo '{"status":"unavailable"}'
  fi
  echo
  echo "=== extracted root files ==="
  echo "envoy_root_pem: $ENVOY_ROOT_PEM"
  echo "spire_root_pem: $SPIRE_ROOT_MATCH_PEM"
} > "$OUT_PATH"
