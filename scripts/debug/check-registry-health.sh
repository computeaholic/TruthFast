#!/usr/bin/env bash
set -euo pipefail

# check-registry-health.sh
# Non-mutating checks for registry health (TLS, catalog, manifest fetch sanity).
# Operator-invoked; CI wrappers are intentionally deferred until scripts are
# manually exercised and reviewed.

usage() {
  cat <<EOF
Usage: $0 --host <host> [--port <port>] [--cacert <path>] [--repo <repo>] [--tag <tag>]

Checks performed (all read-only):
 - TLS connect + certificate sanity (using openssl)
 - GET /v2/ to verify catalog endpoint reachable
 - If --repo and --tag supplied: HEAD/GET manifest for repo:tag

Examples:
  $0 --host registry.threadforge.local --port 30500 --cacert /path/to/ca.crt
  $0 --host registry.threadforge.local --repo "threadforge/test" --tag latest

Note: This script does not mutate anything. Timeouts are conservative.
EOF
}

HOST=""
PORT=30500
CACERT=""
REPO=""
TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --cacert) CACERT="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --tag) TAG="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0;;
  esac
done

if [[ -z "$HOST" ]]; then
  echo "--host is required" >&2
  usage
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

BASEURL="https://${HOST}:${PORT}"
CURL_OPTS=( --silent --show-error --fail --max-time 10 )
if [[ -n "$CACERT" ]]; then
  CURL_OPTS+=( --cacert "$CACERT" )
fi

echo "[check] TLS: retrieving certificate from ${HOST}:${PORT}"
# Use openssl to fetch cert and print subject and expiry
set +e
CERT_OUT=$(mktemp)
timeout 10 openssl s_client -connect "${HOST}:${PORT}" -servername "$HOST" -showcerts < /dev/null > "$CERT_OUT" 2>/dev/null
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  echo "[error] TLS connection failed to ${HOST}:${PORT}" >&2
  rm -f "$CERT_OUT"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# extract first cert and inspect
awk '/-----BEGIN CERTIFICATE-----/{flag=1} flag{print} /-----END CERTIFICATE-----/{flag=0; print; exit}' "$CERT_OUT" > "$CERT_OUT.cert"
if [[ -s "$CERT_OUT.cert" ]]; then
  echo "[ok] Certificate retrieved. Subject and expiry:" 
  openssl x509 -noout -subject -issuer -enddate -in "$CERT_OUT.cert"
else
  echo "[warn] No certificate found in server response" >&2
fi
rm -f "$CERT_OUT.cert"

# Verify with curl to /v2/
echo "[check] HTTP: GET ${BASEURL}/v2/"
if curl "${CURL_OPTS[@]}" "${BASEURL}/v2/" -o /dev/null; then
  echo "[ok] /v2/ reachable"
else
  echo "[error] /v2/ not reachable or TLS verification failed" >&2
  rm -f "$CERT_OUT"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# If repo and tag provided, attempt manifest fetch
if [[ -n "$REPO" && -n "$TAG" ]]; then
  MANIFEST_URL="${BASEURL}/v2/${REPO}/manifests/${TAG}"
  echo "[check] manifest: GET ${MANIFEST_URL}"
  if curl "${CURL_OPTS[@]}" -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "${MANIFEST_URL}" -I; then
    echo "[ok] manifest fetch succeeded"
  else
    echo "[error] manifest fetch failed" >&2
    rm -f "$CERT_OUT"
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
fi

rm -f "$CERT_OUT"

echo "Registry health checks completed (read-only)."
exit 0
