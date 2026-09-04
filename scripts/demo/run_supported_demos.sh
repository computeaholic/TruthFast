#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_ID="supported-demo-all-$(date -u +%Y%m%dT%H%M%SZ)"
ARTIFACT_DIR="${REPO_ROOT}/artifacts/demo-runs/${RUN_ID}"
SOURCE_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
mkdir -p "${ARTIFACT_DIR}"

containment="FAIL"
civ="FAIL"
authority_contrast="FAIL"
security_boundary="FAIL"
source_mutation=0
manual_runtime_repairs=0

tracked_status() {
	git -C "${REPO_ROOT}" status --porcelain --untracked-files=no
}

record_mutation() {
	local phase="$1"
	local status
	status="$(tracked_status)"
	if [[ -n "${status}" ]]; then
		source_mutation=$((source_mutation + 1))
		printf '%s\n' "${status}" >"${ARTIFACT_DIR}/${phase}.source-mutation"
		return 1
	fi
	return 0
}

run_demo() {
	local phase="$1"
	local target="$2"
	local log="${ARTIFACT_DIR}/${phase}.log"
	local before_sha before_status rc

	before_sha="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
	before_status="$(tracked_status)"
	if [[ -n "${before_status}" ]]; then
		echo "[FAIL] ${phase}: worktree is not clean before demo"
		printf '%s\n' "${before_status}" >"${ARTIFACT_DIR}/${phase}.before-mutation"
		return 1
	fi

	echo "[demo-all] ${phase} START target=make ${target}"
	if (cd "${REPO_ROOT}" && MAKEFLAGS= make "${target}") >"${log}" 2>&1; then
		rc=0
	else
		rc=$?
	fi
	cat "${log}"

	if [[ "$(git -C "${REPO_ROOT}" rev-parse HEAD)" != "${before_sha}" ]]; then
		echo "[FAIL] ${phase}: HEAD changed during demo"
		source_mutation=$((source_mutation + 1))
	fi
	if ! record_mutation "${phase}"; then
		echo "[FAIL] ${phase}: tracked source mutation detected"
		rc=1
	fi
	if [[ "${rc}" -ne 0 ]]; then
		echo "[FAIL] ${phase}"
		return "${rc}"
	fi
	echo "[PASS] ${phase}"
	return 0
}

if run_demo CONTAINMENT demo; then containment="PASS"; fi

if [[ "${containment}" == "PASS" ]]; then
	if run_demo CIV demo-civ; then civ="PASS"; fi
fi

if [[ "${civ}" == "PASS" ]]; then
	if run_demo AUTHORITY_CONTRAST demo-authority-contrast; then authority_contrast="PASS"; fi
fi

if [[ "${authority_contrast}" == "PASS" ]]; then
	if run_demo SECURITY_BOUNDARY demo-security-boundary; then security_boundary="PASS"; fi
fi

if [[ -n "$(tracked_status)" ]]; then
	source_mutation=$((source_mutation + 1))
fi

final="FAIL"
if [[ "${containment}" == "PASS" && "${civ}" == "PASS" && \
	"${authority_contrast}" == "PASS" && "${security_boundary}" == "PASS" && \
	"${source_mutation}" -eq 0 && "${manual_runtime_repairs}" -eq 0 ]]; then
	final="PASS"
fi

cat <<EOF
THREADFORGE SUPPORTED DEMO SUMMARY

CONTAINMENT: ${containment}
CIV: ${civ}
AUTHORITY_CONTRAST: ${authority_contrast}
SECURITY_BOUNDARY: ${security_boundary}
SOURCE_MUTATION: ${source_mutation}
SUPPORTED_DEMO_SOURCE_MUTATION: ${source_mutation}
MANUAL_RUNTIME_REPAIRS: ${manual_runtime_repairs}
FINAL: ${final}
SOURCE_SHA: ${SOURCE_SHA}
RUN_ID: ${RUN_ID}
EOF

[[ "${final}" == "PASS" ]]
