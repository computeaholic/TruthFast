#!/usr/bin/env bash
set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
  echo "[FAIL] gh CLI is required"
  exit 2
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "[FAIL] gh CLI is not authenticated"
  exit 2
fi

REPO_SLUG="${GITHUB_REPOSITORY:-}"
if [[ -z "$REPO_SLUG" ]]; then
  url="$(git remote get-url origin 2>/dev/null || true)"
  REPO_SLUG="$(printf '%s\n' "$url" | sed -E 's#^git@github.com:##; s#^https://github.com/##; s#\.git$##')"
fi

if [[ -z "$REPO_SLUG" || "$REPO_SLUG" != */* ]]; then
  echo "[FAIL] unable to resolve repository slug"
  exit 2
fi

echo "[branch-protection] applying settings to ${REPO_SLUG}:main"

gh api \
  --method PUT \
  -H 'Accept: application/vnd.github+json' \
  "/repos/${REPO_SLUG}/branches/main/protection" \
  -f required_status_checks.strict=true \
  -f required_status_checks.contexts[]='pytest' \
  -f required_status_checks.contexts[]='ci-audit' \
  -f required_status_checks.contexts[]='governance-bypass-guard' \
  -f required_status_checks.contexts[]='merge-guard' \
  -F enforce_admins=true \
  -f required_pull_request_reviews.dismiss_stale_reviews=true \
  -f required_pull_request_reviews.require_code_owner_reviews=false \
  -F required_pull_request_reviews.required_approving_review_count=1 \
  -F required_pull_request_reviews.require_last_push_approval=false \
  -F restrictions= \
  -F required_linear_history=true \
  -F allow_force_pushes=false \
  -F allow_deletions=false \
  -F block_creations=false \
  -F required_conversation_resolution=true \
  -F lock_branch=false \
  -F allow_fork_syncing=true >/dev/null

echo "[PASS] branch protection enforced for main"
