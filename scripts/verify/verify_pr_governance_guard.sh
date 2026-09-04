#!/usr/bin/env bash
set -euo pipefail

REQUIRED_CHECKS=()
if [[ -n "${THREADFORGE_REQUIRED_CHECKS:-}" ]]; then
  IFS=, read -r -a REQUIRED_CHECKS <<<"${THREADFORGE_REQUIRED_CHECKS}"
fi

# bypass must appear as a standalone word — not embedded in hyphenated compound
# identifiers such as "governance-bypass-guard".  Require that the character
# immediately preceding and following "bypass" is neither a letter nor a hyphen
# (or that "bypass" appears at the start/end of a line).
BANNED_PATTERN='(no-verify|skip[[:space:]]*hooks|(^|[^[:alpha:]-])bypass([^[:alpha:]-]|$))'

if [[ -z "${GITHUB_REPOSITORY:-}" || -z "${PR_NUMBER:-}" ]]; then
  echo "[FAIL] governance guard requires GITHUB_REPOSITORY and PR_NUMBER"
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "[FAIL] governance guard requires gh CLI"
  exit 2
fi

echo "[governance-guard] repo=${GITHUB_REPOSITORY} pr=${PR_NUMBER}"

PR_JSON="$(gh api "/repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}")"
HEAD_SHA="$(printf '%s\n' "$PR_JSON" | jq -r '.head.sha')"

COMMITS_JSON="$(gh api --paginate "/repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/commits")"
if printf '%s\n' "$COMMITS_JSON" | jq -r '.[].commit.message' | grep -Eqi "$BANNED_PATTERN"; then
  echo "[FAIL] governance guard: forbidden bypass marker found in commit message"
  exit 2
fi

PR_TITLE="$(printf '%s\n' "$PR_JSON" | jq -r '.title // ""')"
PR_BODY="$(printf '%s\n' "$PR_JSON" | jq -r '.body // ""')"
if printf '%s\n%s\n' "$PR_TITLE" "$PR_BODY" | grep -Eqi "$BANNED_PATTERN"; then
  echo "[FAIL] governance guard: forbidden bypass marker found in PR title/body"
  exit 2
fi

if [[ "${#REQUIRED_CHECKS[@]}" -gt 0 ]]; then
  CHECKS_JSON="$(gh api -H 'Accept: application/vnd.github+json' "/repos/${GITHUB_REPOSITORY}/commits/${HEAD_SHA}/check-runs")"

  for check in "${REQUIRED_CHECKS[@]}"; do
    if ! printf '%s\n' "$CHECKS_JSON" | jq -e --arg name "$check" '.check_runs[] | select(.name == $name)' >/dev/null; then
      echo "[FAIL] governance guard: missing required check run on head commit: $check"
      exit 2
    fi

    if ! printf '%s\n' "$CHECKS_JSON" \
      | jq -e --arg name "$check" '.check_runs[] | select(.name == $name) | .conclusion == "success"' >/dev/null; then
      echo "[FAIL] governance guard: required check is not successful on head commit: $check"
      exit 2
    fi
  done
fi

echo "[PASS] governance bypass guard"
