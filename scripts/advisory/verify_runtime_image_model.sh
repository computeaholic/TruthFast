#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ARTIFACT_DIR="${REPO_ROOT}/artifacts"
LAB_RESOLVED="${LAB_RESOLVED:-${REPO_ROOT}/platform/labs/agent-containment/k8s/deployments.resolved.yaml}"
RUNTIME_NAMESPACE="${RUNTIME_NAMESPACE:-agents-lab}"
ALLOWED_SYSTEM_IMAGES_PATH="${ALLOWED_SYSTEM_IMAGES_PATH:-${REPO_ROOT}/scripts/verify/allowed_system_images.txt}"

mkdir -p "${ARTIFACT_DIR}"

runtime_file="$(mktemp)"
declared_file="$(mktemp)"
generated_file="$(mktemp)"
model_file="$(mktemp)"
report_file="${ARTIFACT_DIR}/runtime_image_model.tsv"
unmapped_file="${ARTIFACT_DIR}/runtime_image_unmapped.txt"

cleanup() {
  rm -f "${runtime_file}" "${declared_file}" "${generated_file}" "${model_file}"
}
trap cleanup EXIT

# This check owns the supported containment demo only. The cluster-wide
# runtime image contract is verified by scripts/verify/verify_runtime_images.sh.
kubectl get pods -n "${RUNTIME_NAMESPACE}" -o json \
  | python3 -c 'import json, sys; data=json.load(sys.stdin); [print(c["image"]) for pod in data.get("items", []) if not pod.get("metadata", {}).get("deletionTimestamp") for c in (pod.get("spec", {}).get("initContainers", []) + pod.get("spec", {}).get("containers", []) + pod.get("spec", {}).get("ephemeralContainers", [])) if c.get("image")]' \
  | sort -u > "${runtime_file}"

# Sidecars and other platform-owned images are accepted only from the exact
# existing allowlist. Workload images come from the current resolved manifest.
[[ -f "${ALLOWED_SYSTEM_IMAGES_PATH}" ]] || {
  echo "[FAIL] Allowed system image list is missing: ${ALLOWED_SYSTEM_IMAGES_PATH}" >&2
  exit 2
}
sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "${ALLOWED_SYSTEM_IMAGES_PATH}" >> "${declared_file}"

sort -u -o "${declared_file}" "${declared_file}"

# Generated references are rendered per deploy from freshly built lab images.
if [[ ! -f "${LAB_RESOLVED}" ]]; then
  echo "[FAIL] Missing generated manifest: ${LAB_RESOLVED}" >&2
  exit 2
fi

grep -E '^[[:space:]]*image:[[:space:]]*registry.threadforge.local:30500/' "${LAB_RESOLVED}" \
  | sed -E 's/^[[:space:]]*image:[[:space:]]*//' \
  | sort -u > "${generated_file}"

cat "${declared_file}" "${generated_file}" | sort -u > "${model_file}"

printf 'image\torigin\n' > "${report_file}"
: > "${unmapped_file}"

runtime_count=0
declared_count=0
generated_count=0
unmapped_count=0

while IFS= read -r image; do
  [[ -z "${image}" ]] && continue
  runtime_count=$((runtime_count + 1))

  if grep -Fxq "${image}" "${declared_file}"; then
    printf '%s\tdeclared\n' "${image}" >> "${report_file}"
    declared_count=$((declared_count + 1))
    continue
  fi

  if grep -Fxq "${image}" "${generated_file}"; then
    printf '%s\tgenerated\n' "${image}" >> "${report_file}"
    generated_count=$((generated_count + 1))
    continue
  fi

  printf '%s\tunmapped\n' "${image}" >> "${report_file}"
  echo "${image}" >> "${unmapped_file}"
  unmapped_count=$((unmapped_count + 1))
done < "${runtime_file}"

sort -u -o "${unmapped_file}" "${unmapped_file}"

# Summarize drift for visibility.
declared_only_count="$(comm -23 "${declared_file}" "${runtime_file}" | sed '/^[[:space:]]*$/d' | wc -l | awk '{print $1}')"
generated_only_count="$(comm -23 "${generated_file}" "${runtime_file}" | sed '/^[[:space:]]*$/d' | wc -l | awk '{print $1}')"

echo "[RUNTIME-MODEL] runtime=${runtime_count} declared=${declared_count} generated=${generated_count} unmapped=${unmapped_count}"
echo "[RUNTIME-MODEL] declared-not-running=${declared_only_count} generated-not-running=${generated_only_count}"
echo "[RUNTIME-MODEL] report=${report_file}"

if (( unmapped_count > 0 )); then
  echo "[FAIL] Runtime model mismatch: found ${unmapped_count} unmapped/external image(s)" >&2
  sed 's/^/[UNMAPPED] /' "${unmapped_file}" >&2
  exit 2
fi

echo "[PASS] Runtime images are fully mapped to declared or generated internal references"
