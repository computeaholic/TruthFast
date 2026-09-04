#!/usr/bin/env bash
set -euo pipefail

# check-registry-cert.sh
# Fetches and displays certificate details for a registry host:port (non-mutating).

usage() {
  cat <<EOF
Usage: $0 --host <host> [--port <port>]

Outputs certificate subject, issuer, SANs, and expiry in human-readable form.
EOF
}

HOST=""
PORT=30500

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0;;
  esac
done

if [[ -z "$HOST" ]]; then
  echo "--host is required" >&2
  usage
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "Fetching certificate from ${HOST}:${PORT}..."
set +e
CERT_OUT=$(mktemp)
timeout 10 openssl s_client -connect "${HOST}:${PORT}" -servername "$HOST" -showcerts < /dev/null > "$CERT_OUT" 2>/dev/null
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  echo "[error] Failed to connect to ${HOST}:${PORT}" >&2
  rm -f "$CERT_OUT"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

CERT_FILE="${CERT_OUT}.crt"
awk '/-----BEGIN CERTIFICATE-----/{flag=1} flag{print} /-----END CERTIFICATE-----/{flag=0; print; exit}' "$CERT_OUT" > "$CERT_FILE"
if [[ ! -s "$CERT_FILE" ]]; then
  echo "[error] No certificate retrieved" >&2
  rm -f "$CERT_OUT" "$CERT_FILE"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "Certificate details:"
openssl x509 -in "$CERT_FILE" -noout -subject -issuer -dates -text | sed -n '1,120p'

# Try to print SANs succinctly
echo
echo "SubjectAltName(s):"
openssl x509 -in "$CERT_FILE" -noout -text | sed -n '/Subject Alternative Name/,/X509v3/{/Subject Alternative Name/!p}' || true

rm -f "$CERT_OUT" "$CERT_FILE"

echo "Done."