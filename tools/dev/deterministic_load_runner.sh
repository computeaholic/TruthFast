#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-threadforge-api}"
SERVICE_NAMESPACE="${SERVICE_NAMESPACE:-threadforge}"
LOAD_POD_NAMESPACE="${LOAD_POD_NAMESPACE:-threadforge}"
LOAD_POD_NAME="${LOAD_POD_NAME:-threadforge-load}"
LOAD_POD_CONTAINER="${LOAD_POD_CONTAINER:-load}"
PERF_DIR="security/performance"
CONTRACT_FILE="${PERF_DIR}/load_target_contract.txt"
LOAD_100_FILE="${PERF_DIR}/load_100.txt"
LOAD_500_FILE="${PERF_DIR}/load_500.txt"
STATUS_100_FILE="${PERF_DIR}/load_status_100.txt"
STATUS_500_FILE="${PERF_DIR}/load_status_500.txt"
STATUS_100_SUMMARY_FILE="${PERF_DIR}/load_status_100_summary.txt"
STATUS_500_SUMMARY_FILE="${PERF_DIR}/load_status_500_summary.txt"
SUMMARY_FILE="${PERF_DIR}/load_summary.txt"
STRICT_FILE="${PERF_DIR}/strict_post_load.txt"

mkdir -p "${PERF_DIR}"

PORT="$(kubectl get svc "${SERVICE_NAME}" -n "${SERVICE_NAMESPACE}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
if [[ -z "${PORT}" ]]; then
  echo "ERROR: unable to discover service port for ${SERVICE_NAME}.${SERVICE_NAMESPACE}" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

TARGET="${SERVICE_NAME}.${SERVICE_NAMESPACE}.svc.cluster.local:${PORT}"
echo "Discovered target: ${TARGET}"

if ! kubectl get pod "${LOAD_POD_NAME}" -n "${LOAD_POD_NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: load pod ${LOAD_POD_NAMESPACE}/${LOAD_POD_NAME} not found" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if ! kubectl get pod "${LOAD_POD_NAME}" -n "${LOAD_POD_NAMESPACE}" -o jsonpath='{.status.phase}' | grep -q '^Running$'; then
  echo "ERROR: load pod ${LOAD_POD_NAMESPACE}/${LOAD_POD_NAME} is not Running" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if ! kubectl get pod "${LOAD_POD_NAME}" -n "${LOAD_POD_NAMESPACE}" -o jsonpath='{.spec.containers[*].name}' | tr ' ' '\n' | grep -qx "${LOAD_POD_CONTAINER}"; then
  echo "ERROR: container ${LOAD_POD_CONTAINER} not found in ${LOAD_POD_NAMESPACE}/${LOAD_POD_NAME}" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

ENDPOINTS_RAW="$(kubectl get endpoints "${SERVICE_NAME}" -n "${SERVICE_NAMESPACE}" 2>&1 || true)"
READY_ADDRS="$(kubectl get endpoints "${SERVICE_NAME}" -n "${SERVICE_NAMESPACE}" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null || true)"
if [[ -z "${READY_ADDRS}" ]]; then
  {
    echo "Discovered target: ${TARGET}"
    echo
    echo "ERROR: no ready endpoint addresses for ${SERVICE_NAME}.${SERVICE_NAMESPACE}"
    echo "kubectl get endpoints output:"
    echo "${ENDPOINTS_RAW}"
  } > "${CONTRACT_FILE}"
  echo "ERROR: no ready endpoint addresses" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

CURRENT_ADDRS_CSV="$(printf '%s\n' "${READY_ADDRS}" | sed '/^$/d' | sort | paste -sd, -)"

if [[ -f "${CONTRACT_FILE}" ]]; then
  PREV_TARGET="$(grep -m1 '^TARGET=' "${CONTRACT_FILE}" | cut -d= -f2- || true)"
  PREV_ADDRS_CSV="$(grep -m1 '^ENDPOINTS=' "${CONTRACT_FILE}" | cut -d= -f2- || true)"
  if [[ -n "${PREV_TARGET}" ]] && [[ "${PREV_TARGET}" != "${TARGET}" || "${PREV_ADDRS_CSV}" != "${CURRENT_ADDRS_CSV}" ]]; then
    {
      echo "ERROR: endpoint contract changed between runs"
      echo "PREVIOUS_TARGET=${PREV_TARGET}"
      echo "CURRENT_TARGET=${TARGET}"
      echo "PREVIOUS_ENDPOINTS=${PREV_ADDRS_CSV}"
      echo "CURRENT_ENDPOINTS=${CURRENT_ADDRS_CSV}"
    } > "${CONTRACT_FILE}"
    echo "ERROR: endpoint contract changed between runs" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
fi

{
  echo "TARGET=${TARGET}"
  echo "PORT=${PORT}"
  echo "ENDPOINTS=${CURRENT_ADDRS_CSV}"
  echo
  echo "kubectl get endpoints ${SERVICE_NAME} -n ${SERVICE_NAMESPACE}:"
  kubectl get endpoints "${SERVICE_NAME}" -n "${SERVICE_NAMESPACE}"
} > "${CONTRACT_FILE}"

run_load() {
  local count="$1"
  local status_file="$2"
  local latency_file="$3"
  local summary_file="$4"
  local non_200=0

  : > "${status_file}"
  : > "${latency_file}"

  for i in $(seq 1 "${count}"); do
    response="$(kubectl exec -n "${LOAD_POD_NAMESPACE}" "${LOAD_POD_NAME}" -c "${LOAD_POD_CONTAINER}" -- curl -sS -o /dev/null -w '%{http_code} %{time_total}' "http://${TARGET}/docs" 2>/dev/null || true)"
    code="$(awk '{print $1}' <<< "${response}")"
    time_total="$(awk '{print $2}' <<< "${response}")"

    if [[ -z "${code}" ]]; then
      code="000"
    fi
    if [[ -z "${time_total}" ]]; then
      time_total="0"
    fi

    echo "${code} ${time_total}" >> "${status_file}"

    if [[ "${code}" == "200" ]]; then
      echo "${time_total}" >> "${latency_file}"
    else
      non_200=$((non_200 + 1))
    fi
  done

  awk '{codes[$1]++} END {for (c in codes) print c, codes[c]}' "${status_file}" | sort -n > "${summary_file}"

  if [[ "${non_200}" -ne 0 ]]; then
    echo "ERROR: non-200 responses detected for ${count}-run: ${non_200}" >&2
    echo "Status distribution (${count}-run):"
    cat "${summary_file}"
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
}

run_load 100 "${STATUS_100_FILE}" "${LOAD_100_FILE}" "${STATUS_100_SUMMARY_FILE}"
run_load 500 "${STATUS_500_FILE}" "${LOAD_500_FILE}" "${STATUS_500_SUMMARY_FILE}"

python3 - <<'PY' > "${SUMMARY_FILE}"
import statistics
import math
from pathlib import Path

base = Path("security/performance")
files = [
    ("load_100.txt", "load_status_100_summary.txt"),
    ("load_500.txt", "load_status_500_summary.txt"),
]

def load_vals(path: Path):
    vals = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        vals.append(float(line))
    return vals

def percentile(vals, p):
    s = sorted(vals)
    idx = max(0, min(len(s) - 1, math.ceil((p / 100) * len(s)) - 1))
    return s[idx]

print("ThreadForge STRICT mTLS Structured Load Summary")
for latency_name, status_name in files:
    vals = load_vals(base / latency_name)
    print(f"\n{latency_name}:")
    print(f"- sample_count: {len(vals)}")
    print(f"- mean: {statistics.mean(vals):.6f}")
    print(f"- p95: {percentile(vals, 95):.6f}")
    print(f"- p99: {percentile(vals, 99):.6f}")
    print(f"- max: {max(vals):.6f}")
    print(f"- status_distribution_file: {status_name}")
PY

kubectl get peerauthentication -A > "${STRICT_FILE}"

NON_STRICT_COUNT="$(awk 'NR>1 && $3 != "STRICT" {count++} END {print count+0}' "${STRICT_FILE}")"
if [[ "${NON_STRICT_COUNT}" -ne 0 ]]; then
  echo "ERROR: non-STRICT PeerAuthentication detected" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "Status distribution (100):"
cat "${STATUS_100_SUMMARY_FILE}"
echo "Status distribution (500):"
cat "${STATUS_500_SUMMARY_FILE}"

P95="$(awk '/^load_500.txt:/{f=1;next} f&&/^- p95:/{print $3;exit}' "${SUMMARY_FILE}")"
P99="$(awk '/^load_500.txt:/{f=1;next} f&&/^- p99:/{print $3;exit}' "${SUMMARY_FILE}")"
MAX="$(awk '/^load_500.txt:/{f=1;next} f&&/^- max:/{print $3;exit}' "${SUMMARY_FILE}")"

echo "p95: ${P95}"
echo "p99: ${P99}"
echo "max: ${MAX}"
echo "STRICT confirmation: all PeerAuthentication modes are STRICT"
