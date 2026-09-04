#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFY_LOG="${1:-$REPO_ROOT/artifacts/proof/latest/verify.log}"
OUTPUT_PATH="$REPO_ROOT/artifacts/debug/verify_failure_classifier.log"

if [ ! -f "$VERIFY_LOG" ]; then
	echo "[FAIL] verify log not found: $VERIFY_LOG"
	exit 2
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

current_check=""
current_result=""
current_duration=""
current_context=""
declare -A latest_category_by_check=()
declare -A latest_line_by_check=()
declare -a seen_checks=()

remember_check() {
	local check_name="$1"
	local known="false"
	for existing in "${seen_checks[@]:-}"; do
		if [ "$existing" = "$check_name" ]; then
			known="true"
			break
		fi
	done
	if [ "$known" = "false" ]; then
		seen_checks+=("$check_name")
	fi
}

classify_current() {
	local category=""
	local duration_ms=0
	local signal=""

	if [ -z "$current_check" ]; then
		return 0
	fi

	if [ -n "${latest_category_by_check[$current_check]+set}" ]; then
		current_check=""
		current_result=""
		current_duration=""
		current_context=""
		return 0
	fi

	remember_check "$current_check"

	if [ "$current_result" != "FAIL" ]; then
		latest_category_by_check["$current_check"]="PASS"
		latest_line_by_check["$current_check"]=""
		current_check=""
		current_result=""
		current_duration=""
		current_context=""
		return 0
	fi

	if [[ "$current_duration" =~ ^([0-9]+)ms$ ]]; then
		duration_ms="${BASH_REMATCH[1]}"
	fi

	if [ "$duration_ms" -le 1000 ]; then
		category="INSTANT_PRECONDITION_OR_PATH_FAILURE"
		signal="duration<=1000ms"
	elif printf '%s\n' "$current_context" | grep -Eqi 'MISSING_PREREQ|PROOF_MUTATION_BLOCKED|cluster unreachable|not found|unable to capture|not reachable'; then
		category="INSTANT_PRECONDITION_OR_PATH_FAILURE"
		signal="failure_text_matches_precondition_or_path"
	else
		category="REAL_RUNTIME_FAILURE"
		signal="duration>1000ms"
	fi

	local line="- ${current_check} | duration=${current_duration:-unknown} | signal=${signal}"
	latest_category_by_check["$current_check"]="$category"
	latest_line_by_check["$current_check"]="$line"

	current_check=""
	current_result=""
	current_duration=""
	current_context=""
}

while IFS= read -r line || [ -n "$line" ]; do
	case "$line" in
		CHECK=*)
			classify_current
			current_check="${line#CHECK=}"
			;;
		RESULT=*)
			current_result="${line#RESULT=}"
			current_context+="$line"$'\n'
			;;
		DURATION=*)
			current_duration="${line#DURATION=}"
			current_context+="$line"$'\n'
			;;
		*)
			current_context+="$line"$'\n'
			if printf '%s\n' "$line" | grep -q 'MISSING_PREREQ_CLOSED_LOOP'; then
				remember_check "check_closed_loop_prereqs.sh"
				latest_category_by_check["check_closed_loop_prereqs.sh"]="INSTANT_PRECONDITION_OR_PATH_FAILURE"
				latest_line_by_check["check_closed_loop_prereqs.sh"]="- check_closed_loop_prereqs.sh | duration=inline | signal=MISSING_PREREQ_CLOSED_LOOP"
			fi
			;;
	esac
	if [ "$current_check" = "verify_output_clean.sh" ] && [ -n "$current_duration" ]; then
		break
	fi
done < "$VERIFY_LOG"

classify_current

runtime_count=0
instant_count=0
runtime_lines=()
instant_lines=()

for check_name in "${seen_checks[@]:-}"; do
	if [ -z "${latest_category_by_check[$check_name]:-}" ] || [ "${latest_category_by_check[$check_name]}" = "PASS" ]; then
		continue
	fi
	if [ "${latest_category_by_check[$check_name]}" = "REAL_RUNTIME_FAILURE" ]; then
		runtime_lines+=("${latest_line_by_check[$check_name]}")
		runtime_count=$((runtime_count + 1))
	else
		instant_lines+=("${latest_line_by_check[$check_name]}")
		instant_count=$((instant_count + 1))
	fi
done

{
	echo "Verify Failure Classification"
	echo "Source log: $VERIFY_LOG"
	echo
	echo "REAL_RUNTIME_FAILURE (${runtime_count})"
	if [ "$runtime_count" -eq 0 ]; then
		echo "- none"
	else
		printf '%s\n' "${runtime_lines[@]}"
	fi
	echo
	echo "INSTANT_PRECONDITION_OR_PATH_FAILURE (${instant_count})"
	if [ "$instant_count" -eq 0 ]; then
		echo "- none"
	else
		printf '%s\n' "${instant_lines[@]}"
	fi
} > "$OUTPUT_PATH"

echo "[PASS] wrote $OUTPUT_PATH"
