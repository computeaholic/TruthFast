#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

PROOF_DIR="${VERIFY_MAIN_PROOF_DIR:-artifacts/proof/latest}"
TEST_MODE="${VERIFY_MAIN_TEST_MODE:-false}"
SKIP_REMOTE_CHECKS="${VERIFY_MAIN_SKIP_REMOTE_CHECKS:-false}"
SKIP_PROOF_VERIFICATION="${VERIFY_MAIN_SKIP_PROOF_VERIFICATION:-false}"
MAX_ARTIFACT_COMMIT_SKEW_SECONDS="${VERIFY_MAIN_MAX_ARTIFACT_COMMIT_SKEW_SECONDS:-900}"

FAILURES=0

fail() {
  local message="$1"
  echo "[FAIL] MAIN_INTEGRITY: ${message}"
  FAILURES=$((FAILURES + 1))
}

fail_unverified_commit() {
  echo "[FAIL] UNVERIFIED_COMMIT_IN_MAIN"
  fail "$1"
}

fail_possible_bypass() {
  echo "[FAIL] POSSIBLE_BYPASS_NO_VERIFY"
  fail "$1"
}

require_file() {
  local path="$1"
  [ -f "$path" ] || fail "missing required artifact: $path"
}

extract_repo_slug() {
  local remote url slug
  remote="${1:-origin}"
  url="$(git remote get-url "$remote" 2>/dev/null || true)"
  if [[ -z "$url" ]]; then
    return 1
  fi
  slug="$(printf '%s\n' "$url" | sed -E 's#^git@github.com:##; s#^https://github.com/##; s#\.git$##')"
  if [[ "$slug" != */* ]]; then
    return 1
  fi
  printf '%s\n' "$slug"
}

verify_commit_message_enforcement() {
  local banned_pattern
  banned_pattern='(no-verify|skip[[:space:]]*hooks|(^|[^[:alpha:]-])bypass([^[:alpha:]-]|$))'

  if git log -n 1 --pretty=%B | grep -Eqi "$banned_pattern"; then
    fail "HEAD commit message contains forbidden bypass marker"
  fi
}

verify_proof_artifacts_bound_to_head() {
  local head_sha commit_marker marker_sha
  local commit_epoch artifact_epoch status_epoch determinism_epoch
  local proof_dir_abs
  head_sha="$(git rev-parse HEAD)"
  commit_marker="$PROOF_DIR/commit.sha"

  if [[ "$PROOF_DIR" = /* ]]; then
    proof_dir_abs="$PROOF_DIR"
  else
    proof_dir_abs="$REPO_ROOT/$PROOF_DIR"
  fi

  require_file "$PROOF_DIR/status.json"
  require_file "$PROOF_DIR/hashes.txt"
  require_file "$PROOF_DIR/determinism.json"
  require_file "$commit_marker"

  marker_sha="$(tr -d '[:space:]' < "$commit_marker")"
  if [[ "$marker_sha" != "$head_sha" ]]; then
    fail_unverified_commit "proof artifacts are not bound to HEAD (commit.sha=$marker_sha head=$head_sha)"
  fi

  if ! jq -e '.signed == true and .verified == true and .evidence.signed == true and .evidence.verified == true' "$PROOF_DIR/status.json" >/dev/null 2>&1; then
    fail_unverified_commit "status.json does not assert signed+verified proof evidence"
  fi

  if [[ "$SKIP_PROOF_VERIFICATION" == "true" ]]; then
    if [[ "$TEST_MODE" != "true" ]]; then
      fail "VERIFY_MAIN_SKIP_PROOF_VERIFICATION=true is only allowed in test mode"
    fi
  elif ! bash "$REPO_ROOT/scripts/verify/verify_proof_artifacts.sh" "$proof_dir_abs" >/dev/null; then
    fail_unverified_commit "proof artifacts failed signature/invariant verification"
  fi

  commit_epoch="$(git show -s --format=%ct HEAD)"
  artifact_epoch="$(stat -c %Y "$commit_marker")"
  status_epoch="$(stat -c %Y "$PROOF_DIR/status.json")"
  determinism_epoch="$(stat -c %Y "$PROOF_DIR/determinism.json")"

  if (( artifact_epoch < commit_epoch )); then
    fail_possible_bypass "proof artifact commit marker predates HEAD commit"
  fi
  if (( status_epoch < commit_epoch )); then
    fail_possible_bypass "proof status artifact predates HEAD commit"
  fi
  if (( status_epoch - determinism_epoch > MAX_ARTIFACT_COMMIT_SKEW_SECONDS || determinism_epoch - status_epoch > MAX_ARTIFACT_COMMIT_SKEW_SECONDS )); then
    fail_possible_bypass "proof artifact timestamps are inconsistent"
  fi

  if ! jq -e '.admission_rejection == "PASS" and .ephemeral_containers_blocked == "PASS"' "$PROOF_DIR/status.json" >/dev/null 2>&1; then
    fail_possible_bypass "proof status does not show bypass attempts denied"
  fi
}

verify_head_check_runs() {
  local slug head_sha checks_json check_names failed_names

  if [[ "$SKIP_REMOTE_CHECKS" == "true" ]]; then
    echo "[INFO] REMOTE_CHECK_CONTRACT=NON_BLOCKING reason=remote checks explicitly skipped"
    return
  fi

  slug="$(extract_repo_slug origin || true)"
  head_sha="$(git rev-parse HEAD)"

  if [[ -z "$slug" ]]; then
    echo "[INFO] REMOTE_CHECK_CONTRACT=NON_BLOCKING reason=repository slug unavailable"
    return
  fi

  if ! command -v gh >/dev/null 2>&1; then
    echo "[INFO] REMOTE_CHECK_CONTRACT=NON_BLOCKING reason=gh CLI unavailable"
    return
  fi

  if ! gh auth status >/dev/null 2>&1; then
    echo "[INFO] REMOTE_CHECK_CONTRACT=NON_BLOCKING reason=gh authentication unavailable"
    return
  fi

  if [[ "$TEST_MODE" == "true" && -n "${VERIFY_MAIN_CHECKS_JSON:-}" ]]; then
    checks_json="$VERIFY_MAIN_CHECKS_JSON"
  else
    checks_json="$(gh api \
      -H 'Accept: application/vnd.github+json' \
      "/repos/${slug}/commits/${head_sha}/check-runs" 2>/dev/null || true)"
  fi
  if [[ -z "$checks_json" ]]; then
    echo "[INFO] REMOTE_CHECK_CONTRACT=NON_BLOCKING reason=check-runs unavailable"
    return
  fi

  if ! printf '%s\n' "$checks_json" | jq -e '.check_runs | type == "array"' >/dev/null 2>&1; then
    echo "[INFO] REMOTE_CHECK_CONTRACT=NON_BLOCKING reason=invalid check-runs response"
    return
  fi

  check_names="$(printf '%s\n' "$checks_json" | jq -r '[.check_runs[].name] | unique | join(",")')"
  failed_names="$(printf '%s\n' "$checks_json" | jq -r '[.check_runs[] | select(.conclusion != "success") | .name] | unique | join(",")')"
  if [[ -n "$failed_names" ]]; then
    echo "[INFO] REMOTE_CHECK_CONTRACT=NON_BLOCKING checks=${check_names:-none} failed=${failed_names}"
  else
    echo "[INFO] REMOTE_CHECK_CONTRACT=NON_BLOCKING checks=${check_names:-none}"
  fi
}

main() {
  verify_commit_message_enforcement
  verify_proof_artifacts_bound_to_head
  verify_head_check_runs

  if [[ "$FAILURES" -ne 0 ]]; then
    echo "MAIN_INTEGRITY=FAIL"
    exit 2
  fi

  echo "MAIN_INTEGRITY=PASS"
}

main "$@"
