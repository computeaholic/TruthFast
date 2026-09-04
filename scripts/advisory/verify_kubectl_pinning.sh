#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PIN_FILE="${ROOT}/tools/build/kubectl/PINNED_VERSION"
SUMS_FILE="${ROOT}/tools/build/kubectl/SHA256SUMS"

if [[ ! -f "${PIN_FILE}" ]]; then
  echo "ERROR: missing ${PIN_FILE}" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
if [[ ! -f "${SUMS_FILE}" ]]; then
  echo "ERROR: missing ${SUMS_FILE}" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

ver="$(tr -d ' \t\n\r' <"${PIN_FILE}")"
if [[ ! "${ver}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: invalid pinned kubectl version '${ver}' in ${PIN_FILE}" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

for arch in amd64 arm64; do
  name="kubectl-${ver}-linux-${arch}"
  if ! awk -v n="${name}" '$2==n && $1 ~ /^[0-9a-f]{64}$/ {found=1} END{exit found?0:2}' "${SUMS_FILE}"; then
    echo "ERROR: missing or invalid sha256 entry for ${name} in ${SUMS_FILE}" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
done

echo "OK: kubectl pinned (${ver}) and sha256 entries present for amd64+arm64" >&2
