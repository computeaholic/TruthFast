#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

PIN_FILE="${ROOT}/tools/build/kubectl/PINNED_VERSION"
SUMS_FILE="${ROOT}/tools/build/kubectl/SHA256SUMS"

if [[ ! -f "${PIN_FILE}" ]]; then
  echo "ERROR: missing kubectl pin file: ${PIN_FILE}" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
if [[ ! -f "${SUMS_FILE}" ]]; then
  echo "ERROR: missing kubectl checksum file: ${SUMS_FILE}" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

KUBECTL_VERSION_FROM_PIN="$(tr -d ' \t\n\r' <"${PIN_FILE}")"
KUBECTL_VERSION="${TF_KUBECTL_VERSION:-${KUBECTL_VERSION_FROM_PIN}}"

if [[ "${KUBECTL_VERSION}" != v* ]]; then
  echo "ERROR: pinned kubectl version must start with 'v' (got: '${KUBECTL_VERSION}')" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if [[ -n "${TF_KUBECTL_VERSION:-}" ]] && [[ "${KUBECTL_VERSION}" != "${KUBECTL_VERSION_FROM_PIN}" ]]; then
  echo "ERROR: TF_KUBECTL_VERSION must match tools/build/kubectl/PINNED_VERSION (${KUBECTL_VERSION_FROM_PIN}); got ${KUBECTL_VERSION}" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

uname_m="$(uname -m)"
case "${uname_m}" in
  x86_64) arch="amd64" ;;
  aarch64|arm64) arch="arm64" ;;
  *)
    echo "ERROR: unsupported architecture '${uname_m}' (expected x86_64 or aarch64)" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
    ;;
esac

artifact_name="kubectl-${KUBECTL_VERSION}-linux-${arch}"
expected_sha="$(awk -v name="${artifact_name}" '$2==name{print $1}' "${SUMS_FILE}" | head -n 1)"
if [[ -z "${expected_sha}" ]]; then
  echo "ERROR: no sha256 entry for ${artifact_name} in ${SUMS_FILE}" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

TF_TOOLS_DIR="${TF_TOOLS_DIR:-${ROOT}/.tools}"
bin_dir="${TF_TOOLS_DIR}/bin"
dst="${bin_dir}/kubectl"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

src_path=""
if [[ -n "${TF_KUBECTL_ARTIFACT_DIR:-}" ]]; then
  src_path="${TF_KUBECTL_ARTIFACT_DIR%/}/${artifact_name}"
  if [[ ! -f "${src_path}" ]]; then
    echo "ERROR: TF_KUBECTL_ARTIFACT_DIR is set but artifact missing: ${src_path}" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
  cp "${src_path}" "${tmp_dir}/kubectl"
elif [[ -n "${TF_KUBECTL_ARTIFACT_BASE_URL:-}" ]]; then
  case "${TF_KUBECTL_ARTIFACT_BASE_URL}" in
    http://*|https://*)
      # Hard fail if caller tries to use a public endpoint.
      # Default allowlist is the ThreadForge internal domain; override via TF_KUBECTL_ALLOWED_URL_PREFIXES.
      allowed_prefixes="${TF_KUBECTL_ALLOWED_URL_PREFIXES:-https://registry.threadforge.local}"
      is_allowed="0"
      IFS=',' read -r -a prefixes <<<"${allowed_prefixes}"
      for p in "${prefixes[@]}"; do
        p_trim="${p//[[:space:]]/}"
        if [[ -n "${p_trim}" ]] && [[ "${TF_KUBECTL_ARTIFACT_BASE_URL}" == "${p_trim}"* ]]; then
          is_allowed="1"
          break
        fi
      done
      if [[ "${is_allowed}" != "1" ]]; then
        echo "ERROR: external kubectl download base URL is forbidden: ${TF_KUBECTL_ARTIFACT_BASE_URL}" >&2
        echo "Allowed prefixes: ${allowed_prefixes}" >&2
        echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
      fi
      url="${TF_KUBECTL_ARTIFACT_BASE_URL%/}/${KUBECTL_VERSION}/${artifact_name}"
      curl -fsSL "${url}" -o "${tmp_dir}/kubectl"
      ;;
    file://*)
      base_path="${TF_KUBECTL_ARTIFACT_BASE_URL#file://}"
      src_path="${base_path%/}/${KUBECTL_VERSION}/${artifact_name}"
      if [[ ! -f "${src_path}" ]]; then
        echo "ERROR: artifact missing at ${src_path}" >&2
        echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
      fi
      cp "${src_path}" "${tmp_dir}/kubectl"
      ;;
    *)
      echo "ERROR: TF_KUBECTL_ARTIFACT_BASE_URL must be https://... or file://... (got: ${TF_KUBECTL_ARTIFACT_BASE_URL})" >&2
      echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
      ;;
  esac
else
  echo "ERROR: no internal kubectl source configured." >&2
  echo "Set one of:" >&2
  echo "  - TF_KUBECTL_ARTIFACT_DIR=/path/to/internal/artifacts" >&2
  echo "  - TF_KUBECTL_ARTIFACT_BASE_URL=https://internal-artifacts.example/kubectl" >&2
  echo "  - TF_KUBECTL_ARTIFACT_BASE_URL=file:///path/to/internal/artifacts" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

chmod +x "${tmp_dir}/kubectl"

actual_sha="$(sha256sum "${tmp_dir}/kubectl" | awk '{print $1}')"
if [[ "${actual_sha}" != "${expected_sha}" ]]; then
  echo "ERROR: kubectl sha256 mismatch for ${artifact_name}" >&2
  echo "  expected: ${expected_sha}" >&2
  echo "  actual:   ${actual_sha}" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

mkdir -p "${bin_dir}"
install -m 0755 "${tmp_dir}/kubectl" "${dst}"

client_ver="$(${dst} version --client -o yaml 2>/dev/null | awk '/gitVersion:/{print $2}' | head -n 1 | tr -d '"')"
if [[ "${client_ver}" != "${KUBECTL_VERSION}" ]]; then
  echo "ERROR: installed kubectl reports ${client_ver:-<unknown>}, expected ${KUBECTL_VERSION}" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "OK: kubectl installed at ${dst}" >&2
echo "OK: kubectl version ${KUBECTL_VERSION} (linux/${arch})" >&2
echo "OK: sha256 ${actual_sha}" >&2
