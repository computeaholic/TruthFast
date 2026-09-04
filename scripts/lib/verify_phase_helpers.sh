#!/usr/bin/env bash

verify_contract_doc_path() {
	local repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
	printf '%s\n' "$repo_root/platform/proof/verify_contract.md"
}

observe_contract_doc_path() {
	local repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
	printf '%s\n' "$repo_root/platform/proof/observe_contract.md"
}

verify_contract_type_from_script() {
	local script_path="$1"
	awk -F= '
		/^export VERIFY_TYPE=/ {
			value=$2
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
			gsub(/^"|"$/, "", value)
			print value
			exit 0
		}
	' "$script_path" 2>/dev/null || true
}

verify_contract_type_valid() {
	case "$1" in
		READ_ONLY|ACTIVE|LIVENESS|EVENT)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

observe_contract_type_from_script() {
	local script_path="$1"
	awk -F= '
		/^export OBSERVE_TYPE=/ {
			value=$2
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
			gsub(/^"|"$/, "", value)
			print value
			exit 0
		}
	' "$script_path" 2>/dev/null || true
}

observe_contract_type_valid() {
	case "$1" in
		INGEST|QUERY|CORRELATION|LIVENESS)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

observe_contract_assert_declared() {
	local script_path="$1"
	local observe_type=""
	observe_type="$(observe_contract_type_from_script "$script_path")"
	if [ -z "$observe_type" ]; then
		echo "[FAIL] CONTRACT_VIOLATION: $(basename "$script_path") must export OBSERVE_TYPE=<INGEST|QUERY|CORRELATION|LIVENESS>; see $(observe_contract_doc_path)"
		return 2
	fi
	if ! observe_contract_type_valid "$observe_type"; then
		echo "[FAIL] CONTRACT_VIOLATION: $(basename "$script_path") exports invalid OBSERVE_TYPE=$observe_type; allowed values are INGEST, QUERY, CORRELATION, LIVENESS"
		return 2
	fi
	printf '%s\n' "$observe_type"
	return 0
}

verify_contract_assert_declared() {
	local script_path="$1"
	local verify_type=""
	verify_type="$(verify_contract_type_from_script "$script_path")"
	if [ -z "$verify_type" ]; then
		echo "[FAIL] CONTRACT_VIOLATION: $(basename "$script_path") must export VERIFY_TYPE=<READ_ONLY|ACTIVE|LIVENESS|EVENT>; see $(verify_contract_doc_path)"
		return 2
	fi
	if ! verify_contract_type_valid "$verify_type"; then
		echo "[FAIL] CONTRACT_VIOLATION: $(basename "$script_path") exports invalid VERIFY_TYPE=$verify_type; allowed values are READ_ONLY, ACTIVE, LIVENESS, EVENT"
		return 2
	fi
	printf '%s\n' "$verify_type"
	return 0
}

verify_contract_default_failure_artifact() {
	local script_path="$1"
	local repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
	local base_name="$(basename "$script_path" .sh)"
	printf '%s\n' "$repo_root/artifacts/debug/${base_name}_failure.log"
}

observe_contract_failure_artifact() {
	local repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
	printf '%s\n' "$repo_root/artifacts/debug/observe_failure.log"
}

verify_contract_write_failure_artifact() {
	local artifact_path="$1"
	local script_path="$2"
	local verify_type="$3"
	local mode="$4"
	local reason="$5"
	local output_file="${6:-}"
	local run_id="${PROOF_RUN_ID:-}"

	mkdir -p "$(dirname "$artifact_path")"
	{
		echo "script=$(basename "$script_path")"
		echo "verify_type=$verify_type"
		echo "verify_mode=$mode"
		echo "run_id=$run_id"
		echo "reason=$reason"
		if [ -n "$output_file" ] && [ -f "$output_file" ]; then
			echo "output<<'EOF'"
			cat "$output_file"
			echo "EOF"
		fi
	} > "$artifact_path"
}

observe_contract_write_failure_artifact() {
	local artifact_path="$1"
	local script_path="$2"
	local observe_type="$3"
	local reason="$4"
	local output_file="${5:-}"
	local run_id="${PROOF_RUN_ID:-}"

	mkdir -p "$(dirname "$artifact_path")"
	{
		echo "script=$(basename "$script_path")"
		echo "observe_type=$observe_type"
		echo "run_id=$run_id"
		echo "reason=$reason"
		if [ -n "$output_file" ] && [ -f "$output_file" ]; then
			echo "output<<'EOF'"
			cat "$output_file"
			echo "EOF"
		fi
	} > "$artifact_path"
}

select_active_spire_server_pod() {
	local namespace="${1:-${SPIRE_NS:-spire-system}}"
	local statefulset_pod deployment_pod ready_pod
	statefulset_pod="$(kubectl get pods -n "$namespace" -l app=spire-server -o json 2>/dev/null | jq -r '
		.items[]
		| select(.status.phase == "Running")
		| select(any(.metadata.ownerReferences[]?; .kind == "StatefulSet"))
		| select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
		| .metadata.name
		' | head -n1)"
	if [ -n "$statefulset_pod" ]; then
		printf '%s\n' "$statefulset_pod"
		return 0
	fi
	deployment_pod="$(kubectl get pods -n "$namespace" -l app=spire-server -o json 2>/dev/null | jq -r '
		.items[]
		| select(.status.phase == "Running")
		| select(any(.metadata.ownerReferences[]?; .kind == "ReplicaSet"))
		| select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
		| .metadata.name
		' | head -n1)"
	if [ -n "$deployment_pod" ]; then
		printf '%s\n' "$deployment_pod"
		return 0
	fi
	ready_pod="$(kubectl get pods -n "$namespace" -l app=spire-server -o json 2>/dev/null | jq -r '
		.items[]
		| select(.status.phase == "Running")
		| select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
		| .metadata.name
		' | head -n1)"
	printf '%s\n' "$ready_pod"
}

verify_contract_blocked_in_proof() {
	local verify_type="$1"
	if [ "$verify_type" != "ACTIVE" ]; then
		return 1
	fi
	if [ "${VERIFY_EXECUTION_MODE:-proof}" != "proof" ]; then
		return 1
	fi
	if [ "${THREADFORGE_PROOF_INCLUDE_ACTIVE_VERIFY:-false}" = "true" ]; then
		return 1
	fi
	return 0
}

resolve_real_kubectl() {
	if command -v kubectl >/dev/null 2>&1; then
		type -P kubectl 2>/dev/null || true
	fi
}

proof_kubectl_wrapper_active() {
	if [ "$(type -t kubectl 2>/dev/null || true)" != "function" ]; then
		return 1
	fi
	declare -f kubectl 2>/dev/null | grep -q 'PROOF_MUTATION_BLOCKED'
}

run_real_kubectl() {
	local kubectl_bin="${REAL_KUBECTL_BIN:-}"
	if [ -z "$kubectl_bin" ]; then
		kubectl_bin="$(resolve_real_kubectl)"
	fi
	if [ -z "$kubectl_bin" ]; then
		echo "[FAIL] kubectl not found in PATH" >&2
		return 127
	fi
	"$kubectl_bin" "$@"
}

run_dryrun_after_control_plane_wait() {
	local manifest_file="$1"
	local output_file="$2"
	local repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
	bash "$repo_root/scripts/verify/wait_for_control_plane.sh" >/dev/null
	set +e
	kubectl apply --dry-run=server -f "$manifest_file" >"$output_file" 2>&1
	rc=$?
	set -e
	return "$rc"
}

run_create_after_control_plane_wait() {
	local manifest_file="$1"
	local output_file="$2"
	local repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
	bash "$repo_root/scripts/verify/wait_for_control_plane.sh" >/dev/null
	set +e
	kubectl create -f "$manifest_file" >"$output_file" 2>&1
	rc=$?
	set -e
	if [ "$rc" -eq 0 ]; then
		kubectl delete -f "$manifest_file" --ignore-not-found >/dev/null 2>&1 || true
	fi
	return "$rc"
}

ensure_cluster_readable() {
	if ! run_real_kubectl version --request-timeout=5s >/dev/null 2>&1; then
		echo "[FAIL] cluster unreachable: kubectl version --request-timeout=5s failed"
		return 10
	fi
	return 0
}

fail_if_proof_mutation_blocked() {
	local check_name="$1"
	shift
	local required_ops="$*"
	if proof_kubectl_wrapper_active; then
		echo "[FAIL] MISSING_PREREQ_VERIFY_PATH: ${check_name} requires mutating kubectl operations (${required_ops}) but the proof run exports a read-only kubectl wrapper. This is an instant precondition/path failure, not a runtime verdict."
		exit 2
	fi
}
