#!/usr/bin/env bash

proof_latest_artifact_names() {
	local proof_dir="$1"
	local names=(
		"verify.norm.log"
		"observe.log"
		"observability.json"
		"workload_projection_continuity.json"
		"determinism.json"
	)
	local optional_name=""
	for optional_name in "ca_integrity.json" "gateway_ca_source.json" "failure_behavior.json" "existing_session_fail_closed.json" "sidecar_enforcement_validation.json" "east_west_isolation.json" "north_south_boundary.json" "root_lifecycle_status.json" "successor_root_validation.json"; do
		if [ -f "$proof_dir/$optional_name" ]; then
			names+=("$optional_name")
		fi
	done
	printf '%s\n' "${names[@]}"
}

assert_proof_hashed_artifacts_mutable() {
	if [[ "${ARTIFACT_FROZEN:-0}" -eq 1 || "${PROOF_HASHED_ARTIFACTS_FROZEN:-0}" -eq 1 ]]; then
		echo "[FAIL] POST_FREEZE_HASHED_ARTIFACT_MUTATION" >&2
		return 2
	fi
}

normalize_log() {
	local input_path="$1"
	sed -E '
		s/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.Z+-]+/<TIMESTAMP>/g;
		s/pod-[a-z0-9-]+/<POD>/g;
		s/[0-9a-f]{8,}/<HEX>/g;
		s/^DURATION=[0-9]+ms$/DURATION=<DURATION>/g;
		s@Using Envoy pod for /certs verification: .*@Using Envoy pod for /certs verification: <POD>@g;
	' "$input_path"
}

prepare_proof_hash_inputs() {
	local proof_dir="$1"
	local verify_log="$proof_dir/verify.log"
	local verify_norm_log="$proof_dir/verify.norm.log"

	assert_proof_hashed_artifacts_mutable || return 2

	if [ ! -f "$verify_log" ]; then
		echo "[FAIL] proof artifact missing for normalization: $verify_log" >&2
		return 2
	fi

	normalize_log "$verify_log" > "$verify_norm_log"

	if [ ! -s "$verify_norm_log" ]; then
		echo "[FAIL] normalized proof log was not generated: $verify_norm_log" >&2
		return 2
	fi
}

write_proof_hash_manifest() {
	local proof_dir="$1"
	local hash_manifest="$proof_dir/hashes.txt"
	local artifact_name=""

	assert_proof_hashed_artifacts_mutable || return 2

	if ! prepare_proof_hash_inputs "$proof_dir"; then
		return 2
	fi

	(
		cd "$proof_dir"
		while IFS= read -r artifact_name; do
			if [ ! -f "$artifact_name" ]; then
				echo "[FAIL] proof artifact missing for hash manifest: $proof_dir/$artifact_name" >&2
				return 2
			fi
			sha256sum "$artifact_name"
		done < <(proof_latest_artifact_names "$proof_dir")
	) | LC_ALL=C sort > "$hash_manifest"

	if [ ! -s "$hash_manifest" ]; then
		echo "[FAIL] proof hash manifest was not generated: $hash_manifest" >&2
		return 2
	fi
}
